defmodule Conductor.Workspace do
  @moduledoc """
  Git working trees for runs, one per issue under `<root>/<repo>-issues/<issue number>`, cloned from a local mirror at
  `<root>/mirrors/<repo>.git` so a new workspace costs no network clone.

  `provision/3` is idempotent: on an existing workspace it refreshes the remote refs and leaves a checked-out issue
  branch and any uncommitted work alone, so recovery after a crash continues where the agent was.
  """

  def root,
    do:
      Application.get_env(:conductor, :workspace_root, "~/conductor-workspaces") |> Path.expand()

  def path(repo, issue_key), do: Path.join([root(), "#{repo.name}-issues", issue_key])

  def branch_name(issue_key, snapshot) do
    type = String.downcase((snapshot || %{})["type"] || "")
    if String.contains?(type, "bug"), do: "bugfix/#{issue_key}", else: "feature/#{issue_key}"
  end

  @doc """
  Prepares the workspace of an issue. Returns `{:ok, %{path, branch, base, setup_output}}`; `setup_output` is nil when
  the setup script did not run (none configured, or it already succeeded in this workspace).
  """
  def provision(repo, issue_key, snapshot) do
    path = path(repo, issue_key)
    branch = branch_name(issue_key, snapshot)
    mirror = Path.join([root(), "mirrors", "#{repo.name}.git"])

    with :ok <- update_mirror(repo, mirror),
         :ok <- clone_or_refresh(repo, mirror, path),
         base = base_branch(repo, path),
         :ok <- checkout(path, branch, base),
         {:ok, setup_output} <- setup(repo, path) do
      {:ok, %{path: path, branch: branch, base: base, setup_output: setup_output}}
    end
  end

  def remove(path) when is_binary(path) do
    File.rm_rf(path)
    :ok
  end

  defp update_mirror(repo, mirror) do
    # Two runs of one repository may provision at once; git does not like concurrent fetches into one mirror.
    :global.trans({{__MODULE__, mirror}, self()}, fn ->
      if File.dir?(mirror) do
        git(mirror, ["remote", "update", "--prune"])
      else
        File.mkdir_p!(Path.dirname(mirror))
        git(Path.dirname(mirror), ["clone", "--mirror", repo.clone_url, mirror])
      end
    end)
  end

  defp clone_or_refresh(repo, mirror, path) do
    if File.dir?(Path.join(path, ".git")) do
      git(path, ["fetch", "--prune", mirror, "+refs/heads/*:refs/remotes/origin/*"])
    else
      File.mkdir_p!(Path.dirname(path))
      File.rm_rf!(path)

      with :ok <- git(Path.dirname(path), ["clone", "--local", "--no-checkout", mirror, path]) do
        git(path, ["remote", "set-url", "origin", repo.clone_url])
      end
    end
  end

  @doc "The branch issue branches start from and PRs target: the configured one, else staging when it exists, else main."
  def base_branch(repo, path) do
    cond do
      repo.base_branch not in [nil, ""] -> repo.base_branch
      is_binary(path) and File.dir?(path) and remote_branch?(path, "staging") -> "staging"
      true -> "main"
    end
  end

  defp checkout(path, branch, base) do
    if current_branch(path) == branch do
      :ok
    else
      start = if remote_branch?(path, branch), do: "origin/#{branch}", else: "origin/#{base}"
      git(path, ["switch", "--no-track", "-C", branch, start])
    end
  end

  defp setup(repo, path) do
    marker = Path.join([path, ".git", "conductor-setup-done"])

    cond do
      repo.setup_script in [nil, ""] or String.trim(repo.setup_script) == "" ->
        {:ok, nil}

      File.exists?(marker) ->
        {:ok, nil}

      true ->
        timeout = Application.get_env(:conductor, :setup_timeout_seconds, 1800)

        case run_setup(repo.setup_script, path, timeout) do
          {:ok, output} ->
            File.write!(marker, "")
            {:ok, output}

          {:error, :timeout, output} ->
            {:error, "setup script timed out after #{timeout}s:\n#{tail(output)}"}

          {:error, {:exit_status, status}, output} ->
            {:error, "setup script exited with #{status}:\n#{tail(output)}"}

          {:error, reason, output} ->
            {:error, "setup script failed: #{inspect(reason)}:\n#{tail(output)}"}
        end
    end
  end

  defp run_setup(script, path, timeout) do
    opts = [
      :monitor,
      :stdout,
      :kill_group,
      {:stderr, :stdout},
      {:group, 0},
      {:kill_timeout, 10},
      {:cd, path},
      {:env, git_env()}
    ]

    bash = System.find_executable("bash")

    result =
      if bash do
        :exec.run([bash, "-lc", script], opts)
      else
        {:error, :bash_not_found}
      end

    case result do
      {:ok, pid, os_pid} ->
        deadline = System.monotonic_time(:millisecond) + round(timeout * 1000)

        try do
          collect_setup(pid, os_pid, deadline, [], false)
        after
          :exec.stop(os_pid)
        end

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  defp collect_setup(pid, os_pid, deadline, chunks, timed_out?) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    if remaining == 0 do
      stop_setup(pid, os_pid, chunks, timed_out?)
    else
      receive do
        {:stdout, ^os_pid, data} ->
          collect_setup(pid, os_pid, deadline, [data | chunks], timed_out?)

        {:DOWN, ^os_pid, :process, ^pid, reason} ->
          output = chunks |> Enum.reverse() |> IO.iodata_to_binary()

          case {timed_out?, reason} do
            {true, _} ->
              {:error, :timeout, output}

            {false, :normal} ->
              {:ok, output}

            {false, {:exit_status, status}} ->
              case :exec.status(status) do
                {:status, code} -> {:error, {:exit_status, code}, output}
                signal -> {:error, signal, output}
              end

            {false, reason} ->
              {:error, reason, output}
          end
      after
        remaining -> stop_setup(pid, os_pid, chunks, timed_out?)
      end
    end
  end

  defp stop_setup(pid, os_pid, chunks, timed_out?) do
    :exec.stop(os_pid)

    if timed_out? do
      output = chunks |> Enum.reverse() |> IO.iodata_to_binary()
      {:error, :timeout, output}
    else
      deadline = System.monotonic_time(:millisecond) + 11_000
      collect_setup(pid, os_pid, deadline, chunks, true)
    end
  end

  defp current_branch(path) do
    case System.cmd("git", ["symbolic-ref", "--quiet", "--short", "HEAD"],
           cd: path,
           stderr_to_stdout: true
         ) do
      {name, 0} -> String.trim(name)
      _ -> nil
    end
  end

  defp remote_branch?(path, branch) do
    {_, status} =
      System.cmd("git", ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/#{branch}"],
        cd: path,
        stderr_to_stdout: true
      )

    status == 0
  end

  defp git(cd, args) do
    case System.cmd("git", args, cd: cd, stderr_to_stdout: true, env: git_env()) do
      {_, 0} ->
        :ok

      {output, status} ->
        {:error, "git #{Enum.join(args, " ")} exited with #{status}: #{tail(output)}"}
    end
  end

  defp git_env, do: [{"GIT_TERMINAL_PROMPT", "0"}]

  defp tail(output), do: output |> String.slice(-4000, 4000)
end
