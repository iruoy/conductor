defmodule Conductor.Fixtures do
  @moduledoc "Test data: config rows, runs, a local git remote, and GitHub stubs."
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [start_supervised!: 1]
  alias Conductor.{Config, Repo, Runs}

  def repo_fixture(attrs \\ %{}) do
    {:ok, repo} =
      attrs
      |> Enum.into(%{
        name: "shop-#{System.unique_integer([:positive])}",
        clone_url: "git@github.com:acme/shop.git",
        owner: "acme",
        slug: "shop",
        test_command: "mix test"
      })
      |> Config.create_repo()

    repo
  end

  def project_fixture(attrs \\ %{}) do
    repo = Map.get_lazy(attrs, :repo, fn -> repo_fixture() end)

    {:ok, project} =
      attrs
      |> Map.delete(:repo)
      |> Enum.into(%{
        key: "SHOP",
        runner_login: "conductor-bot",
        pickup_label: "Ready for AI",
        active_label: "In Progress",
        handoff_label: "Review",
        repo_id: repo.id
      })
      |> Config.create_project()

    Repo.preload(project, :repo)
  end

  def settings_fixture(attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        models: %{"head" => %{"provider" => "faux", "modelId" => "faux-1"}},
        max_concurrent: 3
      })

    {:ok, settings} = Config.update_settings(Config.get_settings(), attrs)
    settings
  end

  def snapshot(key, summary \\ "Fix the thing", extra \\ %{}) do
    Map.merge(
      %{
        "key" => key,
        "summary" => summary,
        "type" => "Story",
        "description" => "",
        "labels" => [],
        "subtasks" => []
      },
      extra
    )
  end

  def run_fixture(project, key, attrs \\ %{}) do
    {:ok, run} = Runs.create_run(project, key, attrs[:issue_snapshot] || snapshot(key))
    {:ok, run} = Runs.update_run(run, Map.delete(attrs, :issue_snapshot))
    run
  end

  @doc "A bare repository with `main` (and `staging` unless `staging: false`) to clone from."
  def git_remote(dir, opts \\ []) do
    remote = Path.join(dir, "remote.git")
    work = Path.join(dir, "seed")
    git!(dir, ["init", "--bare", "--initial-branch=main", remote])
    git!(dir, ["init", "--initial-branch=main", work])
    File.write!(Path.join(work, "README.md"), "hello\n")
    git!(work, ["add", "."])
    git!(work, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "init"])
    git!(work, ["push", remote, "main"])

    if Keyword.get(opts, :staging, true) do
      git!(work, ["switch", "-c", "staging"])
      File.write!(Path.join(work, "STAGING.md"), "staging\n")
      git!(work, ["add", "."])
      git!(work, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "staging"])
      git!(work, ["push", remote, "staging"])
    end

    remote
  end

  def git!(cd, args) do
    {output, status} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    assert status == 0, "git #{Enum.join(args, " ")} failed: #{output}"
    String.trim(output)
  end

  @doc """
  GitHub stubs for `acme/shop`: every issue carries the `status` label, the search returns `issues` (maps with
  `number` and `title`), every branch exists unless `branch_exists: false`, and every PR is created anew.
  """
  def stub_github(opts \\ []) do
    test = self()
    issues = Keyword.get(opts, :issues, [])
    status = Keyword.get(opts, :status, "Ready for AI")
    branch_exists = Keyword.get(opts, :branch_exists, true)

    Req.Test.stub(Conductor.GitHub, fn conn ->
      case {conn.method, String.split(conn.request_path, "/", trim: true)} do
        {"GET", ["search", "issues"]} ->
          Req.Test.json(conn, %{"items" => Enum.map(issues, &github_issue(&1, status))})

        {"GET", ["repos", "acme", "shop", "issues", number]} ->
          number = String.to_integer(number)
          default = %{"number" => number, "title" => "Issue #{number}"}
          issue = Enum.find(issues, default, &(&1["number"] == number))
          Req.Test.json(conn, github_issue(issue, status))

        {"GET", ["repos", "acme", "shop", "issues", _number, "sub_issues"]} ->
          Req.Test.json(conn, [])

        {"POST", ["repos", "acme", "shop", "issues", number, "labels"]} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:github_label, String.to_integer(number), JSON.decode!(body)["labels"]})
          Req.Test.json(conn, [])

        {"DELETE", ["repos", "acme", "shop", "issues", _number, "labels", _label]} ->
          Req.Test.json(conn, [])

        {"GET", ["repos", "acme", "shop", "branches" | _branch]} ->
          if branch_exists,
            do: Req.Test.json(conn, %{"name" => "branch"}),
            else: conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})

        {"GET", ["repos", "acme", "shop", "pulls"]} ->
          Req.Test.json(conn, [])

        {"POST", ["repos", "acme", "shop", "pulls"]} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          branch = JSON.decode!(body)["head"]
          Req.Test.json(conn, %{"html_url" => "https://github.com/pr/#{branch}"})
      end
    end)
  end

  defp github_issue(issue, status) do
    %{
      "number" => issue["number"],
      "title" => issue["title"],
      "state" => "open",
      "body" => nil,
      "labels" => [%{"name" => status}]
    }
  end

  @doc """
  Starts the runner (the fake one), Jobs, Coordinator and Poller like the application does. Workspaces go to
  `dir`; GitHub stubs are shared with every process.
  """
  def start_workers(dir, runner_env \\ []) do
    Application.put_env(:conductor, :workspace_root, Path.join(dir, "workspaces"))
    config = Application.get_env(:conductor, Conductor.Runner)
    Application.put_env(:conductor, Conductor.Runner, Keyword.put(config, :env, runner_env))
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:conductor, Conductor.Runner, config) end)
    Req.Test.set_req_test_to_shared()
    start_supervised!(Conductor.Application.workers_spec())
  end

  @doc "Retries `fun` until it stops raising, for state that settles in another OS process."
  def eventually(fun, timeout \\ 5_000) do
    fun.()
  rescue
    error in [ExUnit.AssertionError, MatchError] ->
      if timeout <= 0, do: reraise(error, __STACKTRACE__)
      Process.sleep(50)
      eventually(fun, timeout - 50)
  end
end
