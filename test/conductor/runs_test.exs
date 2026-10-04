defmodule Conductor.RunsTest do
  use Conductor.DataCase, async: false
  import Conductor.Fixtures
  alias Conductor.Runs

  test "messages, tool starts and notes retain their first-persisted order" do
    run = run_fixture(project_fixture(), "SHOP-1")
    user = %{"id" => 1, "kind" => "pi.user"}
    assistant = %{"id" => 2, "kind" => "pi.assistant"}
    result = %{"id" => 3, "kind" => "pi.tool-result"}

    ingest(run, %{"type" => "message_end", "entry" => user})
    ingest(run, %{"type" => "message_end", "entry" => assistant})

    ingest(run, %{
      "type" => "tool_execution_start",
      "toolCallId" => "call-1",
      "toolName" => "bash",
      "args" => %{"command" => "pwd"}
    })

    ingest(run, %{"type" => "message_end", "entry" => result})
    Runs.record_note(run.id, "finished", %{"text" => "Finished"})

    # Both a note and a tool start have NULL positions. They must not be grouped
    # before or after all messages, even when the timestamps are identical.
    assert Enum.map(Runs.list_events(run.id), & &1.entry) == [
             "e:1",
             "e:2",
             "t:call-1",
             "e:3",
             "n:finished"
           ]

    assert Enum.map(Runs.list_events(run.id, 1), & &1.entry) == [
             "e:1",
             "e:2",
             "t:call-1",
             "e:3"
           ]
  end

  test "snapshot replay and payload updates do not move existing events" do
    run = run_fixture(project_fixture(), "SHOP-1")
    user = %{"id" => 1, "kind" => "pi.user"}
    assistant = %{"id" => 2, "kind" => "pi.assistant", "text" => "original"}
    result = %{"id" => 3, "kind" => "pi.tool-result"}

    ingest(run, %{"type" => "snapshot", "entries" => [user, assistant]})

    ingest(run, %{
      "type" => "tool_execution_start",
      "toolCallId" => "call-1",
      "toolName" => "bash",
      "args" => %{}
    })

    ingest(run, %{"type" => "message_end", "entry" => result})
    before = Runs.list_events(run.id, 1)
    updated = Map.put(assistant, "text", "updated")
    ingest(run, %{"type" => "snapshot", "entries" => [user, updated, result]})

    after_replay = Runs.list_events(run.id, 1)
    assert Enum.map(after_replay, & &1.id) == Enum.map(before, & &1.id)
    assert Enum.map(after_replay, & &1.entry) == ["e:1", "e:2", "t:call-1", "e:3"]
    assert Enum.find(after_replay, &(&1.entry == "e:2")).payload == updated
  end

  test "Run and Question are registered Ash resources over the existing tables" do
    assert Conductor.Runs in Application.fetch_env!(:conductor, :ash_domains)
    assert Ash.Domain.Info.resources(Runs) == [Conductor.Runs.Run, Conductor.Runs.Question]
    assert AshPostgres.DataLayer.Info.table(Conductor.Runs.Run) == "runs"
    assert AshPostgres.DataLayer.Info.table(Conductor.Runs.Question) == "questions"
    assert Ash.Resource.Info.primary_key(Conductor.Runs.Run) == [:id]

    assert Ash.Resource.Info.identity(Conductor.Runs.Question, :run_id_qid).keys == [
             :run_id,
             :qid
           ]
  end

  test "attempts, statuses, loaded relationships and manual broadcasts retain their contracts" do
    project = project_fixture()
    Runs.subscribe()
    Runs.subscribe("SHOP-1-1")
    {:ok, first} = Runs.create_run(project, "SHOP-1", %{"priority_rank" => 2})
    assert first.id == "SHOP-1-1"
    assert first.attempt == 1
    assert first.status == :picked_up
    assert_receive {:run_updated, %{id: "SHOP-1-1", project: %{id: project_id}}}
    assert project_id == project.id
    assert_receive {:run_updated, %{id: "SHOP-1-1", project: %{id: ^project_id}}}
    {:ok, second} = Runs.create_run(project, "SHOP-1", %{})
    assert second.id == "SHOP-1-2"
    assert [latest] = Runs.list_runs(1)
    assert latest.id == second.id
    assert latest.project.id == project.id
    assert Runs.get_run(first.id).project.repo.id == project.repo.id
    assert Runs.get_run!(first.id).project.repo.id == project.repo.id
    assert Runs.get_run("missing") == nil
    assert_raise Ash.Error.Invalid, fn -> Runs.get_run!("missing") end
    assert {:error, %Ash.Error.Invalid{}} = Runs.complete(first)
    assert Runs.get_run!(first.id).status == :picked_up
    updated = transition_run(first, :completed, %{summary: "done\n"})
    assert updated.summary == "done\n"
    assert Conductor.Runs.Run.terminal?(updated)
    assert Conductor.Runs.Run.terminal_statuses() == ~w(completed failed)a
    assert is_atom(updated.status)
    assert Runs.open_issue_keys(["SHOP-1", "SHOP-2"]) == ["SHOP-1"]
    assert [queued] = Runs.list_by_status([:picked_up])
    assert queued.id == second.id
    assert queued.project.repo.id == project.repo.id
  end

  test "queue priority, active slots and pruning preserve selection rules" do
    project = project_fixture()
    missing = run_fixture(project, "SHOP-1")
    low = run_fixture(project, "SHOP-2", %{issue_snapshot: %{"priority_rank" => 2}})
    high = run_fixture(project, "SHOP-3", %{issue_snapshot: %{"priority_rank" => 0}})
    run_fixture(project, "SHOP-4", %{issue_snapshot: %{"priority_rank" => 0}})
    old = ~U[2020-01-01 00:00:00Z]
    import Ecto.Query

    Repo.update_all(from(r in Conductor.Runs.Run, where: r.id == ^high.id),
      set: [inserted_at: old]
    )

    assert Runs.next_queued().id == high.id
    assert Runs.active_count() == 0

    for {run, status} <- [{missing, "provisioning"}, {low, "running"}, {high, "handing_off"}] do
      transition_run(run, status)
    end

    assert Runs.active_count() == 3
    {:ok, _} = Runs.wait_for_input(Runs.get_run!(low.id))
    assert Runs.active_count() == 2
    {:ok, _} = Runs.fail(Runs.get_run!(high.id))
    {:ok, _} = Runs.set_workspace_path(Runs.get_run!(high.id), %{workspace_path: "/tmp/old"})

    Repo.update_all(from(r in Conductor.Runs.Run, where: r.id == ^high.id),
      set: [updated_at: old]
    )

    assert [prunable] = Runs.list_prunable(7)
    assert prunable.id == high.id
  end

  test "identity upserts preserve original text, answers, timestamps and row identity" do
    run = run_fixture(project_fixture(), "SHOP-1")
    Runs.subscribe(run.id)
    {:ok, question} = Runs.upsert_question(run.id, "q1", "  original\n")
    assert question.text == "  original\n"
    {:ok, answered} = Runs.answer_question(question, "yes")
    assert_receive {:question, ^answered}
    {:ok, replayed} = Runs.upsert_question(run.id, "q1", "replacement")
    assert replayed.id == question.id
    assert replayed.text == question.text
    assert replayed.answer == "yes"
    assert replayed.answered_at == answered.answered_at
    assert replayed.inserted_at == question.inserted_at
    assert replayed.updated_at == answered.updated_at

    assert :ok =
             Runs.sync_questions(run.id, [
               %{"qid" => "q1", "text" => "replacement", "answered" => true},
               %{"qid" => "q2", "text" => "new", "answered" => true}
             ])

    assert Runs.get_question(run.id, "q1").answer == "yes"
    assert Runs.get_question(run.id, "q2").answered_at
    assert length(Runs.list_questions(run.id)) == 2
    assert length(Ash.load!(Runs.get_run!(run.id), :questions).questions) == 2

    assert :ok =
             Runs.ingest(%{
               "type" => "question",
               "run_id" => run.id,
               "qid" => "q1",
               "text" => "replacement"
             })

    assert_receive {:question, %{id: id, text: "  original\n", answer: "yes"}}
    assert id == question.id

    assert :ok =
             Runs.ingest(%{
               "type" => "question",
               "run_id" => "missing",
               "qid" => "q",
               "text" => "ignored"
             })

    refute_receive {:question, _}
  end

  test "illegal lifecycle transitions and unknown inputs are rejected" do
    project = project_fixture()
    queued = run_fixture(project, "SHOP-20")
    assert {:error, %Ash.Error.Invalid{}} = Runs.complete(queued, %{pr_url: "wrong"})
    assert Runs.get_run!(queued.id).status == :picked_up
    assert {:error, %Ash.Error.Invalid{}} = Runs.pump(queued, %{summary: "not accepted"})

    completed = transition_run(queued, :completed)
    assert {:error, %Ash.Error.Invalid{}} = Runs.resume(completed)
    assert {:error, %Ash.Error.Invalid{}} = Runs.provision_end(completed)
    assert {:error, %Ash.Error.Invalid{}} = Runs.fail(completed, %{error: "late failure"})
    assert Runs.get_run!(queued.id).status == :completed
  end

  test "stale structs cannot overwrite the persisted terminal state" do
    run = run_fixture(project_fixture(), "SHOP-21", %{status: :running})
    {:ok, settled} = Runs.settle(run, %{outcome: "completed"})
    {:ok, _} = Runs.complete(settled)
    assert {:error, %Ash.Error.Invalid{}} = Runs.wait_for_input(run)
    assert {:error, %Ash.Error.Invalid{}} = Runs.fail(run, %{error: "late failure"})
    assert Runs.get_run!(run.id).status == :completed
  end

  test "duplicate and stale run_state events are quietly ignored" do
    run = run_fixture(project_fixture(), "SHOP-22", %{status: :running})
    Runs.subscribe(run.id)
    event = %{"type" => "run_state", "run_id" => run.id, "status" => "running"}
    assert :ok = Runs.ingest(event)
    refute_received {:run_updated, _}
    assert :ok = Runs.ingest(%{event | "status" => "waiting_for_input"})
    assert_receive {:run_updated, %{status: :waiting_for_input}}
    assert :ok = Runs.ingest(%{event | "status" => "waiting_for_input"})
    refute_received {:run_updated, _}
    {:ok, failed} = Runs.fail(Runs.get_run!(run.id), %{error: "original"})
    assert_receive {:run_updated, %{status: :failed}}
    assert :ok = Runs.ingest(event)
    assert :ok = Runs.ingest(%{event | "run_id" => "missing"})
    assert Runs.get_run!(run.id).error == failed.error
    refute_received {:run_updated, _}
  end

  defp ingest(run, event) do
    Runs.ingest(%{
      "type" => "agent_event",
      "run_id" => run.id,
      "conversation" => 1,
      "role" => "head",
      "event" => event
    })
  end
end
