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
    settings_fixture(%{models: %{"head" => %{"provider" => "faux", "modelId" => "faux-2"}}})
    assert Runs.get_run!("shop-4-1").models["head"] == choice
    assert git!(run.workspace_path, ["rev-parse", "--abbrev-ref", "HEAD"]) == "feature/4"
  end

  test "a failed run goes on where it stopped, in the same attempt and workspace", %{
    tmp_dir: dir,
    project: project
  } do
    start_workers(dir)
    {:ok, _} = Coordinator.enqueue(project, "shop-7", snapshot("shop-7", "Work [fake:hang]"))
    assert_receive {:run_updated, %{id: "shop-7-1", status: :running}}, 10_000
    assert {:ok, _} = Runner.call(%{type: "fake_settle", run_id: "shop-7-1", outcome: "failed"})
    assert_receive {:run_updated, %{id: "shop-7-1", status: :failed}}, 10_000

    failed = Runs.get_run!("shop-7-1")
    assert Runs.continuable?(failed)
    assert {:ok, 5} = Coordinator.message("shop-7-1", "")
    assert_receive {:run_updated, %{id: "shop-7-1", status: :running, error: nil}}, 5_000
    assert_receive {:run_updated, %{id: "shop-7-1", status: :completed}}, 10_000

    done = Runs.get_run!("shop-7-1")

    assert {done.attempt, done.workspace_path, done.branch} ==
             {1, failed.workspace_path, failed.branch}
  end

  test "a run the agent failed itself is not handed off and needs a message to go on", %{
    tmp_dir: dir,
    project: project
  } do
    start_workers(dir)
    {:ok, _} = Coordinator.enqueue(project, "shop-8", snapshot("shop-8", "Nope [fake:fail]"))

    assert_receive {:run_updated, %{id: "shop-8-1", status: :failed, error: "could not do it"}},
                   10_000

    refute_received {:github_status, "item-8", "option:Review"}

    assert {:error, "The agent had finished; tell it how to go on."} =
             Coordinator.message("shop-8-1", " ")

    assert %{status: :failed, error: "could not do it"} = Runs.get_run!("shop-8-1")

    assert {:ok, 5} = Coordinator.message("shop-8-1", "The database is back; try again")
    assert_receive {:run_updated, %{id: "shop-8-1", status: :completed}}, 10_000
  end

  test "only the latest attempt that got to run can go on", %{tmp_dir: dir, project: project} do
    start_workers(dir)
    never_ran = run_fixture(project, "shop-9", %{status: :failed})
    refute Runs.continuable?(never_ran)
    assert {:error, :not_continuable} = Coordinator.message(never_ran.id, "")

    models = %{"head" => %{"provider" => "faux", "modelId" => "faux-1"}}
    ran = run_fixture(project, "shop-10", %{status: :running, models: models})
    {:ok, older} = Runs.fail(ran)
    assert Runs.continuable?(older)

    {:ok, _newer} = Runs.create_run(project, "shop-10", snapshot("shop-10"))
    refute Runs.continuable?(older)
    assert {:error, :not_continuable} = Coordinator.message(older.id, "")
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

  test "only failed runs can be retried", %{project: project} do
    for {status, n} <- Enum.with_index(Conductor.Runs.Run.statuses(), 100), status != :failed do
      run = run_fixture(project, "shop-#{n}", %{status: status})
      expected = if Conductor.Runs.Run.terminal?(run), do: :not_retryable, else: :still_open
      assert {:error, ^expected} = Coordinator.retry(run.id)
      assert Runs.other_attempts(run) == []
    end
  end

  test "abort and retry; only the latest attempt can be retried", %{
    tmp_dir: dir,
    project: project
  } do
    start_workers(dir)
    {:ok, _} = Coordinator.enqueue(project, "shop-7", snapshot("shop-7", "Hang [fake:hang]"))
    assert_receive {:run_updated, %{id: "shop-7-1", status: :running}}, 10_000

    assert {:ok, _} = Coordinator.abort("shop-7-1")
    assert_receive {:run_updated, %{id: "shop-7-1", status: :failed, error: "aborted"}}, 5_000

    assert {:ok, %{id: "shop-7-2", attempt: 2}} = Coordinator.retry("shop-7-1")
    assert_receive {:run_updated, %{id: "shop-7-2", status: :completed}}, 10_000
    assert {:error, :not_retryable} = Coordinator.retry("shop-7-1")

    # The server checks again, for a retry that raced the first one past the client-side check.
    first = Runs.get_run!("shop-7-1")

    assert {:reply, {:error, :not_retryable}, _} =
             Coordinator.handle_call({:retry, first.id, first.issue_snapshot}, nil, %{jobs: %{}})
  end

  test "re-sends start_run after the runner crashes mid-run", %{tmp_dir: dir, project: project} do
    start_workers(dir)
    {:ok, _} = Coordinator.enqueue(project, "shop-8", snapshot("shop-8", "Hang [fake:hang]"))
    assert_receive {:run_updated, %{id: "shop-8-1", status: :running}}, 10_000
    coordinator = Process.whereis(Coordinator)

    # :running is broadcast before provisioning's final reads finish. Killing that task during a shared
    # sandbox query disconnects the test transaction, so wait for provisioning to leave the database first.
    for pid <- Task.Supervisor.children(Conductor.Jobs) do
      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, reason} when reason in [:normal, :noproc],
                     5_000
    end

    assert :sys.get_state(coordinator).jobs == %{}

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
