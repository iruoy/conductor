defmodule Conductor.CoordinatorTest do
  use Conductor.DataCase, async: false
  import Conductor.Fixtures
  alias Conductor.{Coordinator, Runner, Runs}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    remote = git_remote(dir)
    project = project_fixture(%{repo: repo_fixture(%{clone_url: remote})})
    settings_fixture()
    stub_github()
    Runs.subscribe()
    %{project: project}
  end

  test "runs at most max_concurrent issues and hands off finished ones", %{
    tmp_dir: dir,
    project: project
  } do
    start_workers(dir)

    for n <- 1..4 do
      key = "SHOP-#{n}"
      assert {:ok, _} = Coordinator.enqueue(project, key, snapshot(key, "Hang [fake:hang]"))
    end

    for _ <- 1..3, do: assert_receive({:run_updated, %{status: "running"}}, 10_000)
    refute_receive {:run_updated, %{status: "running"}}, 300
    assert [%{id: "SHOP-4-1"}] = Runs.list_by_status(["picked_up"])
    assert {:error, :already_open} = Coordinator.enqueue(project, "SHOP-1", snapshot("SHOP-1"))

    assert {:ok, _} =
             Runner.call(%{type: "fake_settle", run_id: "SHOP-1-1", outcome: "completed"})

    assert_receive {:run_updated,
                    %{
                      id: "SHOP-1-1",
                      status: "completed",
                      pr_url: "https://github.com/pr/feature/SHOP-1"
                    }},
                   5_000

    assert_receive {:run_updated, %{id: "SHOP-4-1", status: "running"}}, 10_000
    assert_received {:github_label, 1, ["In Progress"]}
    assert_received {:github_label, 1, ["Review"]}

    run = Runs.get_run!("SHOP-4-1")
    assert run.branch == "feature/SHOP-4"
    assert git!(run.workspace_path, ["rev-parse", "--abbrev-ref", "HEAD"]) == "feature/SHOP-4"
  end

  test "a failed run is not handed off", %{tmp_dir: dir, project: project} do
    start_workers(dir)
    {:ok, _} = Coordinator.enqueue(project, "SHOP-5", snapshot("SHOP-5", "Nope [fake:fail]"))

    assert_receive {:run_updated, %{id: "SHOP-5-1", status: "failed", error: "could not do it"}},
                   10_000
  end

  test "questions wait for an answer", %{tmp_dir: dir, project: project} do
    start_workers(dir)
    {:ok, _} = Coordinator.enqueue(project, "SHOP-6", snapshot("SHOP-6", "Ask [fake:ask]"))
    assert_receive {:run_updated, %{id: "SHOP-6-1", status: "waiting_for_input"}}, 10_000
    assert [%{qid: "q1", text: "Which way?"}] = Runs.list_questions("SHOP-6-1")

    assert {:ok, _} = Coordinator.answer("SHOP-6-1", "q1", "left")
    assert_receive {:run_updated, %{id: "SHOP-6-1", status: "completed"}}, 5_000
    assert [%{answer: "left"}] = Runs.list_questions("SHOP-6-1")
  end

  test "abort and retry", %{tmp_dir: dir, project: project} do
    start_workers(dir)
    {:ok, _} = Coordinator.enqueue(project, "SHOP-7", snapshot("SHOP-7", "Hang [fake:hang]"))
    assert_receive {:run_updated, %{id: "SHOP-7-1", status: "running"}}, 10_000

    assert {:ok, _} = Coordinator.abort("SHOP-7-1")
    assert_receive {:run_updated, %{id: "SHOP-7-1", status: "failed", error: "aborted"}}, 5_000

    assert {:ok, %{id: "SHOP-7-2", attempt: 2}} = Coordinator.retry("SHOP-7-1")
    assert_receive {:run_updated, %{id: "SHOP-7-2", status: "completed"}}, 10_000
  end

  test "re-sends start_run after the runner crashes mid-run", %{tmp_dir: dir, project: project} do
    start_workers(dir)
    {:ok, _} = Coordinator.enqueue(project, "SHOP-8", snapshot("SHOP-8", "Hang [fake:hang]"))
    assert_receive {:run_updated, %{id: "SHOP-8-1", status: "running"}}, 10_000
    coordinator = Process.whereis(Coordinator)

    # The fake keeps no state, so the restarted runner does not know the run.
    assert {:error, :runner_exited} = Runner.call(%{type: "crash"})

    eventually(fn ->
      assert Process.whereis(Coordinator) not in [nil, coordinator]

      assert {:ok, %{"runs" => [%{"run_id" => "SHOP-8-1", "status" => "running"}]}} =
               Runner.call(%{type: "sync"})
    end)

    assert Runs.get_run!("SHOP-8-1").status == "running"
  end

  test "hands off a run that settled while Phoenix was down", %{tmp_dir: dir, project: project} do
    state = Path.join(dir, "runner-state.json")
    run = run_fixture(project, "SHOP-9", %{status: "running", branch: "feature/SHOP-9"})
    settled = %{"outcome" => "completed", "summary" => "Done.\nDONE", "error" => nil}

    File.write!(
      state,
      JSON.encode!(%{run.id => %{"status" => "settled", "settled" => settled, "questions" => []}})
    )

    start_workers(dir, [{"FAKE_RUNNER_STATE", state}])

    assert_receive {:run_updated, %{id: "SHOP-9-1", status: "completed", summary: "Done.\nDONE"}},
                   10_000
  end

  test "picks up a run waiting for input after a restart", %{tmp_dir: dir, project: project} do
    state = Path.join(dir, "runner-state.json")
    run = run_fixture(project, "SHOP-10", %{status: "running"})
    questions = [%{"qid" => "q7", "text" => "Sure?", "answered" => false}]

    File.write!(
      state,
      JSON.encode!(%{run.id => %{"status" => "waiting_for_input", "questions" => questions}})
    )

    start_workers(dir, [{"FAKE_RUNNER_STATE", state}])
    assert_receive {:run_updated, %{id: "SHOP-10-1", status: "waiting_for_input"}}, 10_000
    assert [%{qid: "q7", answered_at: nil}] = Runs.list_questions(run.id)
  end
end
