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
        project_owner: "acme",
        project_number: 1,
        runner_login: "conductor-bot",
        pickup_status: "Ready for AI",
        active_status: "In Progress",
        handoff_status: "Review",
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

  @doc "The issue snapshot of the run key `key` (`shop-4` is issue `#4`)."
  def snapshot(key, summary \\ "Fix the thing", extra \\ %{}) do
    number = Conductor.GitHub.number(key)

    Map.merge(
      %{
        "key" => "##{number}",
        "number" => number,
        "summary" => summary,
        "type" => "Feature",
        "description" => "",
        "labels" => [],
        "item_id" => "item-#{number}",
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
  GitHub stubs for repository `acme/shop` in project `acme/1`: the project holds `issues` (maps with `number` and
  `title`, optionally `priority`), every issue is in `status`, the account's only repository is `acme/shop` and its
  only project `acme/1`, every
  branch exists unless `branch_exists: false`, and every PR is created anew. Status changes are sent to the test as `{:github_status, item, option}`.
  """
  def stub_github(opts \\ []) do
    test = self()
    issues = Keyword.get(opts, :issues, [])
    status = Keyword.get(opts, :status, "Ready for AI")
    branch_exists = Keyword.get(opts, :branch_exists, true)

    Req.Test.stub(Conductor.GitHub, fn conn ->
      case {conn.method, String.split(conn.request_path, "/", trim: true)} do
        {"POST", ["graphql"]} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          %{"query" => query, "variables" => variables} = JSON.decode!(body)
          issue = fn -> github_issue(find_issue(issues, variables["number"]), status) end

          data =
            cond do
              query =~ "query Meta" ->
                %{"repositoryOwner" => %{"projectV2" => github_project()}}

              query =~ "query Items" ->
                nodes =
                  for issue <- issues do
                    issue = github_issue(issue, status)
                    issue["projectItems"]["nodes"] |> hd() |> Map.put("content", issue)
                  end

                page = %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => nodes}
                %{"repositoryOwner" => %{"projectV2" => %{"items" => page}}}

              query =~ "query Issue" or query =~ "query Item" ->
                %{"repository" => %{"issue" => issue.()}}

              query =~ "query Projects" ->
                project =
                  Map.merge(github_project(), %{
                    "number" => 1,
                    "title" => "Shop",
                    "closed" => false,
                    "owner" => %{"login" => "acme"}
                  })

                %{
                  "viewer" => %{
                    "login" => "conductor-bot",
                    "projectsV2" => %{"nodes" => []},
                    "organizations" => %{
                      "nodes" => [%{"projectsV2" => %{"nodes" => [project]}}]
                    }
                  }
                }

              query =~ "mutation SetStatus" ->
                send(test, {:github_status, variables["item"], variables["option"]})
                %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "x"}}}
            end

          Req.Test.json(conn, %{"data" => data})

        {"GET", ["user", "repos"]} ->
          Req.Test.json(conn, [
            %{
              "full_name" => "acme/shop",
              "name" => "shop",
              "owner" => %{"login" => "acme"},
              "ssh_url" => "git@github.com:acme/shop.git",
              "archived" => false
            }
          ])

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

  @doc "The project of `stub_github/1`: its Status and Priority fields."
  def github_project do
    statuses =
      for name <- ["Ready for AI", "In Progress", "Review", "Done"],
          do: %{"id" => "option:#{name}", "name" => name}

    %{
      "id" => "project-1",
      "status" => %{"id" => "status-field", "options" => statuses},
      "priority" => %{"options" => [%{"name" => "P0"}, %{"name" => "P1"}, %{"name" => "P2"}]}
    }
  end

  defp find_issue(issues, number) do
    default = %{"number" => number, "title" => "Issue #{number}"}
    Enum.find(issues, default, &(&1["number"] == number))
  end

  defp github_issue(issue, status) do
    item = %{
      "id" => "item-#{issue["number"]}",
      "project" => %{"id" => "project-1"},
      "status" => %{"name" => status},
      "size" => nil,
      "priority" => issue["priority"] && %{"name" => issue["priority"]}
    }

    %{
      "number" => issue["number"],
      "title" => issue["title"],
      "body" => nil,
      "state" => "OPEN",
      "repository" => %{"nameWithOwner" => "acme/shop"},
      "labels" => %{"nodes" => []},
      "assignees" => %{"nodes" => [%{"login" => "conductor-bot"}]},
      "blockedBy" => %{"nodes" => []},
      "subIssues" => %{"nodes" => []},
      "projectItems" => %{"nodes" => [item]}
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
