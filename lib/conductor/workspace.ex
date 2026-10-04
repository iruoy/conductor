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
        args = ["--kill-after=10", "#{timeout}", "bash", "-lc", repo.setup_script]

        case System.cmd("timeout", args, cd: path, stderr_to_stdout: true, env: git_env()) do
          {output, 0} ->
            File.write!(marker, "")
            {:ok, output}

          {output, 124} ->
            {:error, "setup script timed out after #{timeout}s:\n#{tail(output)}"}

          {output, status} ->
            {:error, "setup script exited with #{status}:\n#{tail(output)}"}
        end
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
