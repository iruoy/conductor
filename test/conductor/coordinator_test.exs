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
      key = "shop-#{n}"
      assert {:ok, _} = Coordinator.enqueue(project, key, snapshot(key, "Hang [fake:hang]"))
    end

    for _ <- 1..3, do: assert_receive({:run_updated, %{status: :running}}, 10_000)
    refute_receive {:run_updated, %{status: :running}}, 300
    assert [%{id: "shop-4-1"}] = Runs.list_by_status([:picked_up])
    assert {:error, :already_open} = Coordinator.enqueue(project, "shop-1", snapshot("shop-1"))

    assert {:ok, _} =
             Runner.call(%{type: "fake_settle", run_id: "shop-1-1", outcome: "completed"})

    assert_receive {:run_updated,
                    %{
                      id: "shop-1-1",
                      status: :completed,
                      pr_url: "https://github.com/acme/shop/pull/1"
                    }},
                   5_000

    assert_receive {:run_updated, %{id: "shop-4-1", status: :running}}, 10_000
    assert_received {:github_status, "item-1", "option:In Progress"}
    assert_received {:github_status, "item-1", "option:Review"}

    run = Runs.get_run!("shop-4-1")
    assert run.branch == "feature/4"

    # The run keeps the models it was started with, whatever the settings say later.
    choice = %{"provider" => "faux", "modelId" => "faux-1"}
    assert run.models == Map.new(~w(head low medium high), &{&1, choice})
    # Older/unavailable classifiers cannot prevent pickup. The audit is durable.
    assert run.classifications["#4"]["status"] == "fallback"
    assert run.classifications["#4"]["complexity"] == "high"
    settings_fixture(%{models: %{"head" => %{"provider" => "faux", "modelId" => "faux-2"}}})
    assert Runs.get_run!("shop-4-1").models["head"] == choice
    assert git!(run.workspace_path, ["rev-parse", "--abbrev-ref", "HEAD"]) == "feature/4"
  end

  test "queued runs start by priority, the oldest first among equals", %{project: project} do
    settings_fixture(%{max_concurrent: 0})

    for {n, rank} <- [{1, 2}, {2, nil}, {3, 0}, {4, 0}] do
      key = "shop-#{n}"
      {:ok, _} = Runs.create_run(project, key, snapshot(key, "T", %{"priority_rank" => rank}))
    end

    order =
      for _ <- 1..4 do
        run = Runs.next_queued()
        {:ok, _} = Runs.fail(run)
        run.issue_key
      end

    assert order == ["shop-3", "shop-4", "shop-1", "shop-2"]
  end

  test "a failed run is not handed off", %{tmp_dir: dir, project: project} do
    start_workers(dir)
    {:ok, _} = Coordinator.enqueue(project, "shop-5", snapshot("shop-5", "Nope [fake:fail]"))

    assert_receive {:run_updated, %{id: "shop-5-1", status: :failed, error: "could not do it"}},
                   10_000
  end

  test "questions wait for an answer", %{tmp_dir: dir, project: project} do
    start_workers(dir)
    {:ok, _} = Coordinator.enqueue(project, "shop-6", snapshot("shop-6", "Ask [fake:ask]"))
    assert_receive {:run_updated, %{id: "shop-6-1", status: :waiting_for_input}}, 10_000
    assert [%{qid: "q1", text: "Which way?"}] = Runs.list_questions("shop-6-1")

    assert {:ok, _} = Coordinator.answer("shop-6-1", "q1", "left")
    assert_receive {:run_updated, %{id: "shop-6-1", status: :completed}}, 5_000
    assert [%{answer: "left"}] = Runs.list_questions("shop-6-1")
  end

  test "abort and retry", %{tmp_dir: dir, project: project} do
    start_workers(dir)
    {:ok, _} = Coordinator.enqueue(project, "shop-7", snapshot("shop-7", "Hang [fake:hang]"))
    assert_receive {:run_updated, %{id: "shop-7-1", status: :running}}, 10_000

    assert {:ok, _} = Coordinator.abort("shop-7-1")
    assert_receive {:run_updated, %{id: "shop-7-1", status: :failed, error: "aborted"}}, 5_000

    assert {:ok, %{id: "shop-7-2", attempt: 2}} = Coordinator.retry("shop-7-1")
    assert_receive {:run_updated, %{id: "shop-7-2", status: :completed}}, 10_000
  end

  test "re-sends start_run after the runner crashes mid-run", %{tmp_dir: dir, project: project} do
    start_workers(dir)
    {:ok, _} = Coordinator.enqueue(project, "shop-8", snapshot("shop-8", "Hang [fake:hang]"))
    assert_receive {:run_updated, %{id: "shop-8-1", status: :running}}, 10_000
    coordinator = Process.whereis(Coordinator)

    # The fake keeps no state, so the restarted runner does not know the run.
    assert {:error, :runner_exited} = Runner.call(%{type: "crash"})

    eventually(fn ->
      assert Process.whereis(Coordinator) not in [nil, coordinator]

      assert {:ok, %{"runs" => [%{"run_id" => "shop-8-1", "status" => "running"}]}} =
               Runner.call(%{type: "sync"})
    end)

    assert Runs.get_run!("shop-8-1").status == :running
  end

  test "hands off a run that settled while Phoenix was down", %{tmp_dir: dir, project: project} do
    state = Path.join(dir, "runner-state.json")
    run = run_fixture(project, "shop-9", %{status: :running, branch: "feature/9"})
    settled = %{"outcome" => "completed", "summary" => "Done.\nDONE", "error" => nil}

    File.write!(
      state,
      JSON.encode!(%{run.id => %{"status" => "settled", "settled" => settled, "questions" => []}})
    )

    start_workers(dir, [{"FAKE_RUNNER_STATE", state}])

    assert_receive {:run_updated, %{id: "shop-9-1", status: :completed, summary: "Done.\nDONE"}},
                   10_000
  end

  test "picks up a run waiting for input after a restart", %{tmp_dir: dir, project: project} do
    state = Path.join(dir, "runner-state.json")
    run = run_fixture(project, "shop-10", %{status: :running})
    questions = [%{"qid" => "q7", "text" => "Sure?", "answered" => false}]

    File.write!(
      state,
      JSON.encode!(%{run.id => %{"status" => "waiting_for_input", "questions" => questions}})
    )

    start_workers(dir, [{"FAKE_RUNNER_STATE", state}])
    assert_receive {:run_updated, %{id: "shop-10-1", status: :waiting_for_input}}, 10_000
    assert [%{qid: "q7", answered_at: nil}] = Runs.list_questions(run.id)
  end

  test "duplicate settlements and late job failures leave runs unchanged", %{project: project} do
    state = %{jobs: %{}}

    for status <- [:picked_up, :handing_off, :completed, :failed] do
      run =
        run_fixture(project, "shop-#{100 + System.unique_integer([:positive])}", %{
          status: status,
          error: "original"
        })

      event =
        {:runner,
         %{
           "type" => "run_settled",
           "run_id" => run.id,
           "outcome" => "completed",
           "error" => "late"
         }}

      assert {:noreply, ^state} = Coordinator.handle_info(event, state)
      assert {:noreply, ^state} = Coordinator.handle_info(event, state)
      assert Runs.get_run!(run.id).status == status
      assert Runs.get_run!(run.id).error == run.error
      if status == :picked_up, do: Runs.fail(run)
    end

    run = run_fixture(project, "shop-999", %{status: :completed})
    ref = make_ref()

    assert {:noreply, ^state} =
             Coordinator.handle_info(
               {ref, {:error, "late job"}},
               %{jobs: %{ref => {:handoff, run.id}}}
             )

    assert Runs.get_run!(run.id).status == :completed
    assert Runs.get_run!(run.id).error == nil
  end
end
