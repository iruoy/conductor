defmodule Conductor.ReviewFollowupTest do
  use Conductor.DataCase, async: false
  import Conductor.Fixtures
  alias Conductor.{Coordinator, Poller, Runner, Runs}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    project = project_fixture(%{repo: repo_fixture(%{clone_url: git_remote(dir)})})
    settings_fixture()
    stub_github()
    start_workers(dir)
    Runs.subscribe()
    %{project: project}
  end

  defp completed_run(project, number) do
    key = "shop-#{number}"
    {:ok, run} = Coordinator.enqueue(project, key, snapshot(key))
    assert_receive {:run_updated, %{id: id, status: :completed}}, 10_000
    assert id == run.id
    Runs.get_run!(id)
  end

  test "feedback reuses the run, workspace, branch, conversation and PR", %{project: project} do
    run = completed_run(project, 71)
    assert_receive {:github_pr_created, "71"}
    assert Runs.active_count() == 0
    assert {:error, :already_open} = Coordinator.enqueue(project, "shop-71", snapshot("shop-71"))

    assert {:ok, 4} = Coordinator.message(run.id, "Please address the review")
    resumed = Runs.get_run!(run.id)
    assert resumed.status == :running
    assert resumed.workspace_path == run.workspace_path
    assert resumed.branch == run.branch
    assert resumed.pr_url == run.pr_url
    assert resumed.models == run.models
    assert resumed.attempt == 1
    assert Runs.active_count() == 1
    assert_receive {:github_status, "item-71", "option:In Progress"}
    assert Enum.any?(Runs.list_events(run.id, 1), &(&1.entry == "e:4"))

    assert {:ok, _} = Runner.call(%{type: "fake_settle", run_id: run.id, outcome: "completed"})
    assert_receive {:run_updated, %{id: "shop-71-1", status: :completed}}, 5_000
    assert Runs.get_run!(run.id).pr_url == run.pr_url
    refute_receive {:github_pr_created, _}
    assert Runs.other_attempts(run) == []
  end

  test "polling confirms a real merge, moves the board to Done and rejects feedback", %{
    project: project
  } do
    run = completed_run(project, 72)
    stub_github(pr_state: "closed", pr_merged: true)
    assert :ok = Poller.poll()
    assert Runs.get_run!(run.id).status == :merged
    assert_receive {:github_status, "item-72", "option:Done"}
    assert {:error, :not_messageable} = Coordinator.message(run.id, "Too late")
    assert List.last(Runs.status_history(run.id)).status == :merged
    assert Runs.open_issue_keys([run.issue_key]) == []
  end

  test "a merge between polls is checked before accepting feedback", %{project: project} do
    run = completed_run(project, 73)
    stub_github(pr_state: "closed", pr_merged: true)
    assert {:error, :pr_merged} = Coordinator.message(run.id, "Too late")
    assert Runs.get_run!(run.id).status == :merged
  end

  test "a board update failure cannot keep a confirmed merge messageable", %{project: project} do
    run = completed_run(project, 78)

    Req.Test.stub(Conductor.GitHub, fn conn ->
      if conn.method == "GET" do
        Req.Test.json(conn, %{"state" => "closed", "merged" => true})
      else
        conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"message" => "Forbidden"})
      end
    end)

    assert {:error, :pr_merged} = Coordinator.message(run.id, "Too late")
    assert Runs.get_run!(run.id).status == :merged
  end

  test "closed PRs and API failures do not restart the runner", %{project: project} do
    run = completed_run(project, 74)
    stub_github(pr_state: "closed")
    assert {:error, :pr_closed} = Coordinator.message(run.id, "Feedback")
    assert Runs.get_run!(run.id).status == :completed

    Req.Test.stub(Conductor.GitHub, fn conn ->
      conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"message" => "Forbidden"})
    end)

    assert {:error, _} = Coordinator.message(run.id, "Feedback")
    assert Runs.get_run!(run.id).status == :completed
  end

  test "review feedback respects concurrency and requires the original workspace", %{
    project: project
  } do
    run = completed_run(project, 75)
    settings_fixture(%{max_concurrent: 0})
    assert {:error, :concurrency_limit} = Coordinator.message(run.id, "Feedback")
    settings_fixture()
    File.rm_rf!(run.workspace_path)
    assert {:error, :workspace_unavailable} = Coordinator.message(run.id, "Feedback")
    assert {:error, :empty_message} = Coordinator.message(run.id, "  ")
    assert Runs.get_run!(run.id).status == :completed
  end

  test "a runner rejection returns the run to review", %{project: project, tmp_dir: dir} do
    run =
      run_fixture(project, "shop-76", %{
        status: :completed,
        workspace_path: dir,
        pr_url: "https://github.com/acme/shop/pull/76"
      })

    assert {:error, _} = Coordinator.message(run.id, "Feedback")
    assert Runs.get_run!(run.id).status == :completed
    assert List.last(Runs.status_history(run.id)).status == :completed
  end

  test "unmerged review workspaces are not pruned", %{project: project, tmp_dir: dir} do
    run = run_fixture(project, "shop-77", %{status: :completed, workspace_path: dir})

    Repo.update_all(from(r in Conductor.Runs.Run, where: r.id == ^run.id),
      set: [updated_at: ~U[2020-01-01 00:00:00Z]]
    )

    assert :ok = Poller.prune()
    assert File.dir?(dir)
    assert Runs.get_run!(run.id).workspace_path == dir
  end
end
