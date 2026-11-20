defmodule Conductor.RunsTest do
  use Conductor.DataCase, async: false
  import Conductor.Fixtures
  alias Conductor.Runs

  @idle %{"busy" => false, "message" => nil, "retry" => nil, "tools" => [], "inbox" => []}

  describe "runs" do
    test "create_run numbers attempts and broadcasts to both topics with the project loaded" do
      project = project_fixture()
      Runs.subscribe()
      Runs.subscribe("SHOP-1-1")

      {:ok, first} = Runs.create_run(project, "SHOP-1", snapshot("SHOP-1"))
      assert %{id: "SHOP-1-1", attempt: 1, status: :picked_up} = first
      project_id = project.id

      for _ <- 1..2,
          do: assert_receive({:run_updated, %{id: "SHOP-1-1", project: %{id: ^project_id}}})

      {:ok, second} = Runs.create_run(project, "SHOP-1", snapshot("SHOP-1"))
      assert second.id == "SHOP-1-2"
      assert [%{id: "SHOP-1-2"} | _] = Runs.filter_runs(:all)
      assert Runs.get_run!(first.id).project.repo.id == project.repo.id
      assert Runs.get_run("missing") == nil
      assert Runs.open_issue_keys(["SHOP-1", "SHOP-2"]) == ["SHOP-1"]
    end

    test "other_attempts lists the other runs of the same issue, the first attempt first" do
      project = project_fixture()
      first = run_fixture(project, "SHOP-1", %{status: :failed})
      second = run_fixture(project, "SHOP-1", %{status: :failed})
      third = run_fixture(project, "SHOP-1", %{status: :running})
      run_fixture(project, "SHOP-2")

      assert Enum.map(Runs.other_attempts(second), & &1.id) == [first.id, third.id]
    end

    test "next_queued takes the highest priority, the oldest among equals, unranked last" do
      project = project_fixture()

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
      assert Runs.next_queued() == nil
    end

    test "a run waiting for a human does not hold a slot" do
      project = project_fixture()

      for {key, status} <- [
            {"SHOP-1", :provisioning},
            {"SHOP-2", :running},
            {"SHOP-3", :handing_off},
            {"SHOP-4", :waiting_for_input},
            {"SHOP-5", :picked_up}
          ],
          do: run_fixture(project, key, %{status: status})

      assert Runs.active_count() == 3
    end

    test "illegal transitions and stale structs cannot change a terminal run" do
      run = run_fixture(project_fixture(), "SHOP-21", %{status: :running})
      assert {:error, %Ash.Error.Invalid{}} = Runs.complete(run)

      {:ok, settled} = Runs.settle(run, %{outcome: "completed"})
      {:ok, _} = Runs.complete(settled)
      # `run` still says :running; the write is checked against the database.
      assert {:error, %Ash.Error.Invalid{}} = Runs.wait_for_input(run)
      assert {:error, %Ash.Error.Invalid{}} = Runs.fail(run, %{error: "late failure"})
      assert Runs.get_run!(run.id).status == :completed
    end
  end

  describe "ingest/1 of run_state" do
    test "moves a run between running and waiting, ignoring duplicates, stale states and unknown runs" do
      run = run_fixture(project_fixture(), "SHOP-22", %{status: :running})
      Runs.subscribe(run.id)
      event = %{"type" => "run_state", "run_id" => run.id, "status" => "running"}

      assert :ok = Runs.ingest(event)
      refute_received {:run_updated, _}
      assert :ok = Runs.ingest(%{event | "status" => "waiting_for_input"})
      assert_receive {:run_updated, %{status: :waiting_for_input}}
      assert :ok = Runs.ingest(%{event | "status" => "waiting_for_input"})
      refute_received {:run_updated, _}

      {:ok, _} = Runs.fail(Runs.get_run!(run.id), %{error: "original"})
      assert_receive {:run_updated, %{status: :failed}}
      assert :ok = Runs.ingest(event)
      assert :ok = Runs.ingest(%{event | "run_id" => "missing"})
      assert %{status: :failed, error: "original"} = Runs.get_run!(run.id)
      refute_received {:run_updated, _}
    end
  end

  describe "status_history/1" do
    test "keeps every status of a run through its lifecycle, in order and with its time" do
      {:ok, run} = Runs.create_run(project_fixture(), "SHOP-30", snapshot("SHOP-30"))
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
    end

    test "only a change of status adds to it" do
      run = run_fixture(project_fixture(), "SHOP-34", %{status: :running, workspace_path: "/t"})
      {:ok, run} = Runs.set_branch(run, %{branch: "conductor/shop-34"})
      {:ok, run} = Runs.clear_workspace(run)
      assert {:error, %Ash.Error.Invalid{}} = Runs.complete(run)
      :ok = Runs.ingest(%{"type" => "run_state", "run_id" => run.id, "status" => "running"})

      assert Enum.map(Runs.status_history(run.id), & &1.status) ==
               ~w(picked_up provisioning running)a

      assert Runs.status_history("missing") == []
    end
  end

  describe "questions" do
    test "replays keep the original text and answer, and every write is broadcast" do
      run = run_fixture(project_fixture(), "SHOP-1")
      Runs.subscribe(run.id)
      {:ok, question} = Runs.upsert_question(run.id, "q1", "original")
      assert_receive {:question, %{qid: "q1", answer: nil}}
      {:ok, _} = Runs.answer_question(question, "yes")
      assert_receive {:question, %{qid: "q1", answer: "yes"}}

      ingest = %{"type" => "question", "run_id" => run.id, "qid" => "q1", "text" => "replaced"}
      assert :ok = Runs.ingest(ingest)
      assert_receive {:question, %{id: id, text: "original", answer: "yes"}}
      assert id == question.id

      assert :ok = Runs.ingest(%{ingest | "run_id" => "missing"})
      refute_receive {:question, _}
    end

    test "sync_questions marks answered ones and adds missing ones" do
      run = run_fixture(project_fixture(), "SHOP-1")
      {:ok, _} = Runs.upsert_question(run.id, "q1", "Known?")

      assert :ok =
               Runs.sync_questions(run.id, [
                 %{"qid" => "q1", "text" => "Known?", "answered" => true},
                 %{"qid" => "q2", "text" => "New?", "answered" => false}
               ])

      assert [%{qid: "q1", answered_at: %DateTime{}}, %{qid: "q2", answered_at: nil}] =
               Runs.list_questions(run.id)
    end
  end

  describe "ingest/1 of agent events" do
    test "an update without entries is broadcast and persists nothing" do
      run = run_fixture(project_fixture(), "CODE-1")
      Runs.subscribe(run.id)

      nested = %{"callId" => "code/c1", "name" => "bash", "parentCallId" => "code"}
      event = %{"type" => "update", "live" => %{@idle | "busy" => true, "tools" => [nested]}}

      ingest(run, event)
      assert_receive {:agent_event, %{conversation: 1, role: "head", event: ^event}}
      assert Runs.list_events(run.id) == []
      refute_received {:run_updated, _}
    end

    test "entries and notes are ordered by conversation, position and id" do
      run = run_fixture(project_fixture(), "SHOP-1")

      for {id, kind} <- [{1, "pi.user"}, {2, "pi.assistant"}, {3, "pi.tool-result"}],
          do: ingest(run, %{"type" => "update", "entries" => [%{"id" => id, "kind" => kind}]})

      Runs.record_note(run.id, "finished", %{"text" => "Finished"})

      assert Enum.map(Runs.list_events(run.id), & &1.entry) == ["n:finished", "e:1", "e:2", "e:3"]
      assert Enum.map(Runs.list_events(run.id, 1), & &1.entry) == ["e:1", "e:2", "e:3"]
    end

    test "conversations are listed in the order they started" do
      run = run_fixture(project_fixture(), "SHOP-1")
      entry = %{"type" => "update", "entries" => [%{"id" => 1, "kind" => "pi.user"}]}
      ingest(run, entry, 2, "sub:#7")
      ingest(run, entry)
      Runs.record_note(run.id, "finished", %{"text" => "Finished"})

      assert Runs.conversations(run.id) == [{2, "sub:#7"}, {1, "head"}, {0, "conductor"}]
    end

    test "snapshot replays update payloads in place and drop system entries" do
      run = run_fixture(project_fixture(), "SHOP-1")
      # More than one insert chunk of 100.
      entries = for id <- 1..201, do: %{"id" => id, "kind" => "pi.assistant", "text" => "old"}
      system = %{"id" => 0, "kind" => "pi.system"}

      ingest(run, %{"type" => "snapshot", "entries" => [system | entries], "live" => @idle})
      before = Runs.list_events(run.id, 1)

      updated = Enum.map(entries, &Map.put(&1, "text", "new"))
      ingest(run, %{"type" => "snapshot", "entries" => [system | updated], "live" => @idle})
      after_replay = Runs.list_events(run.id, 1)

      assert length(after_replay) == 201
      assert Enum.map(after_replay, & &1.id) == Enum.map(before, & &1.id)
      assert Enum.map(after_replay, & &1.position) == Enum.to_list(1..201)
      assert Enum.all?(after_replay, &(&1.payload["text"] == "new"))
    end

    test "invalid transcript rows are logged and dropped without raising" do
      run = run_fixture(project_fixture(), "SHOP-12")

      assert ExUnit.CaptureLog.capture_log(fn ->
               ingest(run, %{"type" => "snapshot", "entries" => [%{"id" => 1, "kind" => nil}]})
             end) =~ "dropping transcript events"

      assert Runs.list_events(run.id) == []
    end

    test "compaction failures are kept apart from the transcript until a feed clears them" do
      run = run_fixture(project_fixture(), "COMPACT-1", %{status: :running})
      ingest(run, %{"type" => "update", "entries" => [%{"id" => 1, "kind" => "pi.user"}]})
      failure = %{"taskId" => 7, "reason" => "threshold", "error" => "Provider unavailable"}
      ingest(run, %{"type" => "update", "compactionFailure" => failure})
      assert Runs.compaction_failures(run.id) == %{1 => "Provider unavailable"}
      assert [%{kind: "pi.user"}] = Runs.list_events(run.id)
      assert Runs.conversation_ends(run.id) == %{1 => :working}

      # An update that says nothing of compaction leaves the failure as it is.
      ingest(run, %{"type" => "update", "live" => @idle})
      assert Runs.compaction_failures(run.id) == %{1 => "Provider unavailable"}
      ingest(run, %{"type" => "update", "compactionFailure" => nil})
      assert Runs.compaction_failures(run.id) == %{}

      # A snapshot always says, and replaces what an update said.
      ingest(run, %{"type" => "update", "compactionFailure" => failure})
      ingest(run, %{"type" => "snapshot", "entries" => [], "compactionFailure" => nil})
      assert Runs.compaction_failures(run.id) == %{}
    end

    test "conversation_models/1 reads each conversation's model from its first answer" do
      run = run_fixture(project_fixture(), "SHOP-60")

      answer = fn conversation, role, id, message ->
        entry = %{"id" => id, "kind" => "pi.assistant", "model" => [message]}
        ingest(run, %{"type" => "update", "entries" => [entry]}, conversation, role)
      end

      faux = %{"role" => "assistant", "provider" => "faux", "model" => "faux-1"}
      answer.(1, "head", 2, Map.put(faux, "thinkingLevel", "high"))
      answer.(1, "head", 5, %{faux | "model" => "faux-later"})
      answer.(2, "sub:#7", 3, %{faux | "model" => "faux-small"})
      answer.(3, "sub:#8", 4, %{"role" => "assistant"})

      assert Runs.conversation_models(run.id) == %{
               1 => %{"provider" => "faux", "modelId" => "faux-1", "reasoning" => "high"},
               2 => %{"provider" => "faux", "modelId" => "faux-small"}
             }
    end
  end

  describe "filter_runs/2" do
    setup do
      project = project_fixture()
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

      assert %{all: 4, running: 2, failed: 1, completed: 1, merged: 0, waiting: 0, picked_up: 0} =
               Runs.group_counts()
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

  defp ingest(run, event, conversation \\ 1, role \\ "head") do
    Runs.ingest(%{
      "type" => "agent_event",
      "run_id" => run.id,
      "conversation" => conversation,
      "role" => role,
      "event" => event
    })
  end
end
