defmodule Conductor.RunsTest do
  use Conductor.DataCase, async: false
  import Conductor.Fixtures
  require Ash.Query
  alias Conductor.Runs

  test "messages, tool starts and notes are ordered by conversation, position and id" do
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

    # Notes belong to conversation 0; NULL positions sort after positioned messages.
    assert Enum.map(Runs.list_events(run.id), & &1.entry) == [
             "n:finished",
             "e:1",
             "e:2",
             "e:3",
             "t:call-1"
           ]

    assert Enum.map(Runs.list_events(run.id, 1), & &1.entry) == [
             "e:1",
             "e:2",
             "e:3",
             "t:call-1"
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
    assert Enum.map(after_replay, & &1.entry) == ["e:1", "e:2", "e:3", "t:call-1"]
    assert Enum.find(after_replay, &(&1.entry == "e:2")).payload == updated
  end

  test "ANSI escapes survive JSONL decoding, transcript persistence and PubSub streaming" do
    run = run_fixture(project_fixture(), "SHOP-56")
    Runs.subscribe(run.id)

    ansi = "\e[31mVitest output\e[0m"

    entry = %{
      "id" => 44,
      "kind" => "pi.tool-result",
      "model" => [
        %{
          "role" => "toolResult",
          "toolCallId" => "ansi-call",
          "toolName" => "bash",
          "content" => [%{"type" => "text", "text" => ansi}],
          "isError" => false
        }
      ]
    }

    message = %{
      "type" => "agent_event",
      "run_id" => run.id,
      "conversation" => 7,
      "role" => "head",
      "event" => %{"type" => "message_end", "entry" => entry}
    }

    # Exercise one encoded stdout JSONL record through line framing and Phoenix's JSON decoder.
    jsonl = Jason.encode!(message) <> "\n"
    [line] = String.split(jsonl, "\n", trim: true)
    decoded = Jason.decode!(line)
    assert :ok = Runs.ingest(decoded)
    assert_receive {:agent_event, %{event: %{"entry" => ^entry}}}
    assert [%{payload: ^entry}] = Runs.list_events(run.id, 7)
    assert List.first(entry["model"])["content"] == [%{"type" => "text", "text" => ansi}]
  end

  test "replaying a snapshot twice is unique and uses one SQL statement per chunk" do
    run = run_fixture(project_fixture(), "SHOP-12")
    entries = for id <- 1..201, do: %{"id" => id, "kind" => "pi.assistant"}
    system = %{"id" => 0, "kind" => "pi.system"}
    handler = "transcript-queries-#{System.unique_integer([:positive])}"
    owner = self()

    :telemetry.attach(
      handler,
      [:conductor, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == owner, do: send(owner, {:transcript_sql, metadata.query})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    for _ <- 1..2 do
      ingest(run, %{"type" => "snapshot", "entries" => [system | entries]})

      for _ <- 1..3 do
        assert_receive {:transcript_sql, sql}
        assert sql =~ "INSERT INTO \"run_events\""
        assert sql =~ "ON CONFLICT"
      end

      refute_received {:transcript_sql, _}
    end

    events = Runs.list_events(run.id, 1)
    assert length(events) == 201
    assert Enum.map(events, & &1.position) == Enum.to_list(1..201)
    assert Enum.uniq_by(events, &{&1.run_id, &1.conversation, &1.entry}) == events
    assert Enum.all?(events, &(&1.role == "head"))
    assert Enum.all?(events, &(&1.kind == "pi.assistant"))
    assert Runs.list_events(run.id, 0) == []
  end

  test "invalid transcript rows are logged and dropped without raising" do
    run = run_fixture(project_fixture(), "SHOP-12")

    assert ExUnit.CaptureLog.capture_log(fn ->
             ingest(run, %{"type" => "snapshot", "entries" => [%{"id" => 1, "kind" => nil}]})
           end) =~ "dropping transcript events"

    assert Runs.list_events(run.id) == []
    Runs.record_note(run.id, "setup", %{"text" => "ok"})
    assert [%{conversation: 0, role: "conductor", entry: "n:setup"}] = Runs.list_events(run.id)
  end

  test "Run, Question and Event are registered Ash resources over the existing tables" do
    assert Conductor.Runs in Application.fetch_env!(:conductor, :ash_domains)

    assert Ash.Domain.Info.resources(Runs) == [
             Conductor.Runs.Run,
             Conductor.Runs.Run.Version,
             Conductor.Runs.Question,
             Conductor.Runs.Event
           ]

    assert AshPostgres.DataLayer.Info.table(Conductor.Runs.Event) == "run_events"

    assert Ash.Resource.Info.identity(Conductor.Runs.Event, :run_id_conversation_entry).keys ==
             [:run_id, :conversation, :entry]

    assert AshPostgres.DataLayer.Info.table(Conductor.Runs.Run) == "runs"
    assert AshPostgres.DataLayer.Info.table(Conductor.Runs.Question) == "questions"
    assert Ash.Resource.Info.primary_key(Conductor.Runs.Run) == [:id]

    assert Ash.Resource.Info.identity(Conductor.Runs.Question, :run_id_qid).keys == [
             :run_id,
             :qid
           ]
  end

  test "attempts, statuses, loaded relationships and notifier broadcasts retain their contracts" do
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

  test "other_attempts lists the other runs of the same issue, the first attempt first" do
    project = project_fixture()
    first = run_fixture(project, "SHOP-1", %{status: :failed})
    second = run_fixture(project, "SHOP-1", %{status: :failed})
    third = run_fixture(project, "SHOP-1", %{status: :running})
    run_fixture(project, "SHOP-2")

    assert Enum.map(Runs.other_attempts(second), &{&1.id, &1.status}) ==
             [{first.id, :failed}, {third.id, :running}]

    assert Runs.other_attempts(run_fixture(project, "SHOP-3")) == []
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
    assert_receive {:question, %{id: question_id, answer: nil}}
    assert question_id == question.id
    assert question.text == "  original\n"
    {:ok, answered} = Runs.answer_question(question, "yes")
    assert_receive {:question, %{id: ^question_id, answer: "yes"}}
    {:ok, replayed} = Runs.upsert_question(run.id, "q1", "replacement")
    assert_receive {:question, %{id: ^question_id, answer: "yes"}}
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

    assert_receive {:question, %{qid: "q1", answer: "yes"}}
    assert_receive {:question, %{qid: "q2", answered_at: nil}}
    assert_receive {:question, %{qid: "q2", answered_at: answered_at}}
    assert answered_at
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

  describe "status_history/1" do
    test "keeps every status of a run through its lifecycle, in order and with its time" do
      project = project_fixture()
      {:ok, run} = Runs.create_run(project, "SHOP-30", snapshot("SHOP-30"))
      assert [%{status: :picked_up, at: %DateTime{}}] = Runs.status_history(run.id)

      {:ok, run} = Runs.pump(run)
      {:ok, run} = Runs.provision_end(run)
      state = %{"type" => "run_state", "run_id" => run.id, "status" => "waiting_for_input"}
      assert :ok = Runs.ingest(state)
      assert :ok = Runs.ingest(%{state | "status" => "running"})
      {:ok, run} = Runs.settle(Runs.get_run!(run.id), %{outcome: "completed", summary: "Done"})
      {:ok, run} = Runs.complete(run, %{pr_url: "https://github.com/acme/shop/pull/7"})

      history = Runs.status_history(run.id)

      assert Enum.map(history, & &1.status) ==
               ~w(picked_up provisioning running waiting_for_input running handing_off completed)a

      times = Enum.map(history, & &1.at)
      assert times == Enum.sort(times, DateTime)
      assert history |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 7
    end

    test "every way to fail is kept" do
      project = project_fixture()

      for {key, from, action} <- [
            {"SHOP-31", :picked_up, :abort},
            {"SHOP-32", :running, :fail},
            {"SHOP-33", :handing_off, :hand_off_failed}
          ] do
        run = run_fixture(project, key, %{status: from})
        {:ok, _failed} = apply(Runs, action, [run])
        assert %{status: :failed} = List.last(Runs.status_history(run.id))
      end
    end

    test "only a change of status adds to it" do
      project = project_fixture()
      run = run_fixture(project, "SHOP-34", %{status: :running, workspace_path: "/tmp/ws"})
      other = run_fixture(project, "SHOP-35")
      {:ok, run} = Runs.set_branch(run, %{branch: "conductor/shop-34"})
      {:ok, run} = Runs.clear_workspace(run)

      # Neither a transition that is refused, nor a state the run is already in.
      assert {:error, %Ash.Error.Invalid{}} = Runs.complete(run)

      assert :ok =
               Runs.ingest(%{"type" => "run_state", "run_id" => run.id, "status" => "running"})

      assert Enum.map(Runs.status_history(run.id), & &1.status) ==
               ~w(picked_up provisioning running)a

      assert Enum.map(Runs.status_history(other.id), & &1.status) == [:picked_up]
      assert Runs.status_history("missing") == []
    end

    test "a version holds the status and the action, and no copy of the run" do
      models = %{"head" => %{"provider" => "faux", "modelId" => "faux-1"}}
      run = run_fixture(project_fixture(), "SHOP-36", %{status: :running, models: models})
      assert Runs.get_run!(run.id).models == models

      {:ok, _settled} =
        Runs.settle(run, %{outcome: "failed", summary: "No", error: "Tests failed"})

      versions =
        Conductor.Runs.Run.Version
        |> Ash.Query.filter(version_source_id == ^run.id)
        |> Ash.Query.sort([:version_inserted_at, :id])
        |> Ash.read!()

      assert Enum.map(versions, &{&1.version_action_name, &1.status, &1.changes}) == [
               {:create, :picked_up, %{}},
               {:pump, :provisioning, %{}},
               {:provision_end, :running, %{}},
               {:settle, :handing_off, %{}}
             ]
    end

    test "a bulk update of the status is kept too" do
      project = project_fixture()
      runs = for key <- ~w(SHOP-37 SHOP-38), do: run_fixture(project, key, %{status: :running})
      ids = Enum.map(runs, & &1.id)

      result =
        Conductor.Runs.Run
        |> Ash.Query.filter(id in ^ids)
        |> Ash.bulk_update(:fail, %{error: "stopped"}, strategy: [:atomic, :atomic_batches])

      assert result.status == :success

      for id <- ids do
        assert Runs.get_run!(id).status == :failed
        assert %{status: :failed} = List.last(Runs.status_history(id))
        assert length(Runs.status_history(id)) == 4
      end
    end
  end

  test "conversation_models/1 reads each conversation's model from its first answer" do
    run = run_fixture(project_fixture(), "SHOP-60")
    other = run_fixture(project_fixture(), "SHOP-61")

    answer = fn run, conversation, role, id, message ->
      Runs.ingest(%{
        "type" => "agent_event",
        "run_id" => run.id,
        "conversation" => conversation,
        "role" => role,
        "event" => %{
          "type" => "message_end",
          "entry" => %{"id" => id, "kind" => "pi.assistant", "model" => [message]}
        }
      })
    end

    faux = %{"role" => "assistant", "provider" => "faux", "model" => "faux-1"}
    answer.(run, 1, "head", 2, Map.put(faux, "thinkingLevel", "high"))
    answer.(run, 1, "head", 5, %{faux | "model" => "faux-later"})
    answer.(run, 2, "sub:#7", 3, %{faux | "model" => "faux-small"})
    # An answer that names no model, as nothing the runner sends does.
    answer.(run, 3, "sub:#8", 4, %{"role" => "assistant"})
    answer.(other, 1, "head", 2, %{faux | "model" => "faux-other"})

    assert Runs.conversation_models(run.id) == %{
             1 => %{"provider" => "faux", "modelId" => "faux-1", "reasoning" => "high"},
             2 => %{"provider" => "faux", "modelId" => "faux-small"}
           }

    assert Runs.conversation_models("missing") == %{}
  end

  describe "filter_runs/3" do
    setup do
      project = project_fixture(%{repo: repo_fixture()})
      run_fixture(project, "shop-1", %{status: :running})
      run_fixture(project, "shop-2", %{status: :provisioning})
      run_fixture(project, "shop-3", %{status: :failed, error: "boom"})

      run_fixture(project, "shop-4", %{
        status: :completed,
        issue_snapshot: snapshot("shop-4", "Reset 100% of the Cache_keys")
      })

      :ok
    end

    test "filters by status group and counts the whole group" do
      assert ["shop-2-1", "shop-1-1"] = Enum.map(Runs.filter_runs(:running), & &1.id)
      assert [%{id: "shop-3-1"}] = Runs.filter_runs(:failed)
      assert length(Runs.filter_runs(:all)) == 4

      assert %{all: 4, running: 2, failed: 1, completed: 1, waiting: 0, picked_up: 0} =
               Runs.group_counts()

      assert Runs.count_runs(:running) == 2
      assert length(Runs.filter_runs(:all, "", 1)) == 1
      assert Runs.count_runs(:all) == 4
    end

    test "matches id and summary case-insensitively, taking wildcards literally" do
      assert [%{id: "shop-3-1"}] = Runs.filter_runs(:all, "SHOP-3")
      assert [%{id: "shop-4-1"}] = Runs.filter_runs(:all, "cache_KEYS")
      assert [%{id: "shop-4-1"}] = Runs.filter_runs(:all, "100%")
      assert [] = Runs.filter_runs(:all, "cache%keys")
      assert [] = Runs.filter_runs(:failed, "cache")
      assert Runs.count_runs(:all, "fix the thing") == 3
    end

    test "matches?/3 agrees with the query" do
      for group <- Runs.status_groups(), text <- ["", "shop-3", "CACHE_keys", "nope"] do
        expected = Runs.filter_runs(group, text) |> Enum.map(& &1.id) |> Enum.sort()

        actual =
          Runs.filter_runs(:all)
          |> Enum.filter(&Runs.matches?(&1, group, text))
          |> Enum.map(& &1.id)
          |> Enum.sort()

        assert actual == expected
      end
    end
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
