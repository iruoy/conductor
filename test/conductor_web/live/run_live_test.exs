defmodule ConductorWeb.RunLiveTest do
  use ConductorWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Conductor.Fixtures
  alias Conductor.{Coordinator, Runs}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    project = project_fixture(%{repo: repo_fixture(%{clone_url: git_remote(dir)})})
    settings_fixture()
    stub_github()
    start_workers(dir)
    Runs.subscribe()
    %{project: project}
  end

  # A conversation's live state as the runner sends it; idle unless told otherwise.
  defp live_state(fields \\ %{}) do
    Map.merge(
      %{"busy" => false, "message" => nil, "retry" => nil, "tools" => [], "inbox" => []},
      fields
    )
  end

  # What the runner reports for one conversation of a run.
  defp agent_event(run_id, conversation, role, event) do
    Runs.ingest(%{
      "type" => "agent_event",
      "run_id" => run_id,
      "conversation" => conversation,
      "role" => role,
      "event" => event
    })
  end

  defp entries(run_id, conversation, role, entries),
    do: agent_event(run_id, conversation, role, %{"type" => "update", "entries" => entries})

  defp prompt_entry(id, text),
    do: %{"id" => id, "kind" => "pi.user", "model" => [%{"role" => "user", "content" => text}]}

  defp assert_unique_ids(view) do
    ids =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[id]")
      |> LazyHTML.attribute("id")

    assert ids |> Enum.frequencies() |> Enum.filter(fn {_id, count} -> count > 1 end) == []
  end

  describe "live agent output" do
    test "streams live text and tool output, then folds it into the transcript", %{
      conn: conn,
      project: project
    } do
      run = run_fixture(project, "shop-3", %{status: :running})
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
      send_event = &agent_event(run.id, 4, "head", &1)

      busy = fn fields ->
        send_event.(%{"type" => "update", "live" => live_state(Map.put(fields, "busy", true))})
      end

      streaming = &busy.(%{"message" => %{"text" => &1, "thinking" => &2}})

      send_event.(%{
        "type" => "update",
        "entries" => [prompt_entry(0, "Go")],
        "live" => live_state(%{"busy" => true})
      })

      # Nothing has come in yet: the agent is at work.
      assert has_element?(view, "#indicator .loading")

      # Thinking shows as it streams in, and becomes a closed line when the text starts.
      streaming.("", "Let me see")
      assert has_element?(view, "#live-thinking[data-thinking]", "Thinking")
      assert has_element?(view, "#live-thinking", "Let me see")
      refute has_element?(view, "#indicator")

      # Markdown is rendered, and HTML in it is shown as text.
      streaming.("Thinking out loud in **bold** <script>x</script>", "Let me see")
      assert has_element?(view, "#live [data-from=agent] .prose strong", "bold")
      assert has_element?(view, "details#live-thinking:not([open])", "Thought")
      refute has_element?(view, "#live script")

      # The transcript and what streams in share one scroller.
      assert has_element?(view, "#transcript-scroller[phx-hook] [role=log] #transcript")
      assert has_element?(view, "#transcript-scroller [role=log] #live")

      tool = %{
        "callId" => "t1",
        "name" => "bash",
        "args" => %{"command" => "mix test"},
        "output" => "",
        "parentCallId" => nil
      }

      # A tool shows once it has output, which comes whole each time.
      busy.(%{"tools" => [tool]})
      refute has_element?(view, "#live-tool-t1")
      busy.(%{"tools" => [%{tool | "output" => "3 tests"}]})
      assert has_element?(view, "#live-tool-t1", "3 tests")
      busy.(%{"tools" => [%{tool | "output" => "3 tests, 0 failures"}]})
      assert has_element?(view, "#live-tool-t1 [data-tool-status=running]", "running")
      assert has_element?(view, "#live-tool-t1", "3 tests, 0 failures")

      # The answer that calls the tool ends what streamed; the tool still runs.
      call = %{"type" => "toolCall", "id" => "t1", "name" => "bash", "arguments" => %{}}
      message = %{"content" => [call], "stopReason" => "toolUse"}
      entry = %{"id" => 1, "kind" => "pi.assistant", "model" => [message]}

      running =
        live_state(%{"busy" => true, "tools" => [%{tool | "output" => "3 tests, 0 failures"}]})

      send_event.(%{"type" => "update", "entries" => [entry], "live" => running})
      refute has_element?(view, "#live [data-from=agent]")
      assert has_element?(view, "#live-tool-t1", "3 tests, 0 failures")

      # Once the result is in, it shows on the tool call.
      result = %{
        "role" => "toolResult",
        "toolCallId" => "t1",
        "toolName" => "bash",
        "durationMs" => 1250,
        "content" => [%{"type" => "text", "text" => "all green"}]
      }

      entries(run.id, 4, "head", [%{"id" => 2, "kind" => "pi.tool-result", "model" => [result]}])
      assert has_element?(view, "#items-ev-4-e-1-0 [data-tool=bash]", "all green")
      assert has_element?(view, "#tool-t1-duration", "1.3s")
      refute has_element?(view, "#items-ev-4-e-2")

      # What the agent does between two texts is one group of steps, which says what goes on while it works.
      thought = %{"type" => "thinking", "thinking" => "So it works."}
      again = %{"type" => "toolCall", "id" => "t2", "name" => "bash", "arguments" => %{}}
      message = %{"content" => [thought, again], "stopReason" => "toolUse"}
      entries(run.id, 4, "head", [%{"id" => 4, "kind" => "pi.assistant", "model" => [message]}])

      summary = "#items-ev-4-e-1-0 > details:not([open]) > summary"
      assert has_element?(view, summary <> " [data-row-text]", "Running commands")
      assert has_element?(view, summary <> " > [data-pulse]")
      assert has_element?(view, "#items-ev-4-e-1-0 [data-steps] details", "So it works.")
      assert has_element?(view, "#items-ev-4-e-1-0 [data-steps] [data-tool-status=running]")
      refute has_element?(view, "#items-ev-4-e-4-0")

      # A message that calls no tool closes the group.
      busy.(%{})
      refute has_element?(view, "#live-tool-t1")
      done = %{"content" => [%{"type" => "text", "text" => "Done."}], "stopReason" => "stop"}
      entries(run.id, 4, "head", [%{"id" => 5, "kind" => "pi.assistant", "model" => [done]}])
      assert has_element?(view, summary <> " [data-row-text]", "Thought, ran 2 commands")
      refute has_element?(view, summary <> " > [data-pulse]")

      # The same shows after a reload.
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
      assert has_element?(view, summary <> " [data-row-text]", "Thought, ran 2 commands")
      assert has_element?(view, "#items-ev-4-e-1-0 [data-steps] [data-tool=bash]", "all green")
      assert has_element?(view, "#tool-t1-duration", "1.3s")
      refute has_element?(view, "#items-ev-4-e-2")
      refute has_element?(view, "#items-ev-4-e-4-0")
    end

    test "folds a finished turn into one row before its answer", %{conn: conn, project: project} do
      run = run_fixture(project, "shop-5", %{status: :running})
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      send_entry = fn id, kind, message ->
        entries(run.id, 4, "head", [%{"id" => id, "kind" => kind, "model" => [message]}])
      end

      call = %{"type" => "toolCall", "id" => "t1", "name" => "bash", "arguments" => %{}}

      result = %{
        "role" => "toolResult",
        "toolCallId" => "t1",
        "toolName" => "bash",
        "content" => "a.ex",
        "durationMs" => 250
      }

      send_entry.(1, "pi.user", %{"role" => "user", "content" => "Find it", "timestamp" => 1_000})

      send_entry.(2, "pi.assistant", %{
        "content" => [
          %{"type" => "text", "text" => "Looking around."},
          call,
          %{call | "id" => "t2"}
        ],
        "stopReason" => "toolUse",
        "model" => "gpt-6.1-sol",
        "durationMs" => 1500
      })

      send_entry.(3, "pi.tool-result", result)
      send_entry.(5, "pi.tool-result", %{result | "toolCallId" => "t2", "durationMs" => 600})

      # While the turn goes on, everything shows.
      response = "#items-ev-4-e-2-response"
      assert has_element?(view, response <> " [data-from=agent]", "Looking around.")

      assert has_element?(
               view,
               response <> " [data-model-response] > header",
               "gpt-6.1-sol · 1.5s"
             )

      assert has_element?(view, response <> " #tool-t1-duration", "250ms")
      assert has_element?(view, response <> " #tool-t2-duration", "600ms")
      refute has_element?(view, "[data-work]")
      assert_unique_ids(view)

      {:ok, loaded, _} = live(conn, ~p"/runs/#{run.id}")
      assert_unique_ids(loaded)

      send_entry.(4, "pi.assistant", %{
        "content" => [%{"type" => "text", "text" => "It is there."}],
        "stopReason" => "stop",
        "timestamp" => 126_000,
        "model" => "gpt-6.1-sol",
        "durationMs" => 2200
      })

      # The answer ends the turn: the work before it folds into one closed row, live and after a reload.
      {:ok, reloaded, _} = live(conn, ~p"/runs/#{run.id}")

      for view <- [view, loaded, reloaded] do
        assert_unique_ids(view)
        folded = "#items-ev-4-e-2-response-work > details:not([open])"
        assert has_element?(view, folded <> " > summary [data-row-text]", "Ran 2 commands")
        assert has_element?(view, folded <> " > summary [data-row-meta]", "2m 5s")
        assert has_element?(view, folded <> " [data-work] [data-from=agent]", "Looking around.")
        assert has_element?(view, folded <> " [data-work] [data-tool=bash]", "a.ex")

        assert has_element?(
                 view,
                 folded <> " [data-model-response] > header",
                 "gpt-6.1-sol · 1.5s"
               )

        assert has_element?(view, folded <> " #tool-t2-duration", "600ms")
        refute has_element?(view, "[data-work] details details")
        refute has_element?(view, "[data-work] #ev-4-e-4-timing")

        assert has_element?(view, "#items-ev-4-e-4-response [data-from=agent]", "It is there.")

        assert has_element?(
                 view,
                 "#items-ev-4-e-4-response [data-model-response] > #ev-4-e-4-timing",
                 "gpt-6.1-sol · 2.2s"
               )
      end
    end

    test "the first prompt of each conversation is the issue, later ones are you", %{
      conn: conn,
      project: project
    } do
      run = run_fixture(project, "shop-15", %{status: :running})
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      entries(run.id, 4, "head", [prompt_entry(1, "The issue")])
      entries(run.id, 4, "head", [prompt_entry(2, "Use tabs")])
      eventually(fn -> assert has_element?(view, "#items-ev-4-e-2") end)
      assert has_element?(view, "#items-ev-4-e-1 [data-label]", "Issue")
      assert has_element?(view, "#items-ev-4-e-2 [data-label]", "You")

      # Another conversation starts with a first prompt of its own, also when it is opened before it has one.
      entries(run.id, 5, "sub:#16", [prompt_entry(1, "The subtask")])
      eventually(fn -> assert has_element?(view, "#tab-5") end)
      view |> element("#tab-5") |> render_click()
      assert has_element?(view, "#items-ev-5-e-1 [data-label]", "Issue")
      entries(run.id, 5, "sub:#16", [prompt_entry(2, "Go on")])
      eventually(fn -> assert has_element?(view, "#items-ev-5-e-2 [data-label]", "You") end)

      # A page that loads the transcript marks the same one.
      view |> element("#tab-4") |> render_click()
      assert has_element?(view, "#items-ev-4-e-1 [data-label]", "Issue")
      assert has_element?(view, "#items-ev-4-e-2 [data-label]", "You")
    end

    test "a restarted codemode script restores nested tool output from its snapshot", %{
      conn: conn,
      project: project
    } do
      run = run_fixture(project, "code-1", %{status: :running})
      {:ok, view, _} = live(conn, ~p"/runs/#{run.id}")

      tool = %{
        "callId" => "code-c1",
        "name" => "bash",
        "args" => %{"command" => "pwd"},
        "output" => "Restored output",
        "parentCallId" => "code"
      }

      agent_event(run.id, 1, "head", %{
        "type" => "snapshot",
        "entries" => [],
        "compactionFailure" => nil,
        "live" => live_state(%{"busy" => true, "tools" => [tool]})
      })

      assert has_element?(view, "#live-tool-code-c1", "Restored output")

      agent_event(run.id, 1, "head", %{
        "type" => "update",
        "live" => live_state(%{"busy" => true})
      })

      refute has_element?(view, "#live-tool-code-c1")
    end

    test "compaction warnings survive reload and clear when the runner reports recovery", %{
      conn: conn,
      project: project
    } do
      run = run_fixture(project, "compact-1", %{status: :running})
      failure = %{"error" => "Provider unavailable"}
      agent_event(run.id, 1, "head", %{"type" => "update", "compactionFailure" => failure})

      {:ok, view, _} = live(conn, ~p"/runs/#{run.id}")
      assert has_element?(view, "#compaction-failure[role=alert]", "Provider unavailable")
      # An update that does not mention compaction keeps the warning.
      agent_event(run.id, 1, "head", %{"type" => "update", "live" => live_state()})
      assert has_element?(view, "#compaction-failure", "Provider unavailable")
      agent_event(run.id, 1, "head", %{"type" => "update", "compactionFailure" => nil})
      refute has_element?(view, "#compaction-failure")
      {:ok, reloaded, _} = live(conn, ~p"/runs/#{run.id}")
      refute has_element?(reloaded, "#compaction-failure")
    end

    test "empty setup output does not create a Conductor tab, but real logs do", %{
      conn: conn,
      project: project
    } do
      run = run_fixture(project, "setup-38", %{status: :running})
      Runs.record_note(run.id, "setup", %{"title" => "Setup script", "text" => " \n\t"})
      {:ok, view, _} = live(conn, ~p"/runs/#{run.id}")
      refute has_element?(view, "#tab-0")
      refute has_element?(view, "[data-note]")

      Runs.record_note(run.id, "setup", %{"title" => "Setup script", "text" => "Installed"})
      {:ok, view, _} = live(conn, ~p"/runs/#{run.id}")
      assert has_element?(view, "#tab-0")
      assert has_element?(view, "[data-note] pre", "Installed")
    end
  end

  describe "talking to the agent" do
    test "answers the open question and the run goes on", %{conn: conn, project: project} do
      {:ok, _} = Coordinator.enqueue(project, "shop-2", snapshot("shop-2", "Ask [fake:ask]"))
      assert_receive {:run_updated, %{id: "shop-2-1", status: :waiting_for_input}}, 10_000

      {:ok, view, html} = live(conn, ~p"/runs/shop-2-1")
      assert html =~ "<h1>#2: Ask [fake:ask]</h1>"
      assert has_element?(view, "form#answer-q1 #question-q1", "Which way?")

      view |> form("#answer-q1", %{"text" => "left"}) |> render_submit()
      assert_receive {:run_updated, %{id: "shop-2-1", status: :completed}}, 5_000
      eventually(fn -> assert render(view) =~ "Did it." end)
      refute render(view) =~ "Which way?"
      assert [%{answer: "left"}] = Runs.list_questions("shop-2-1")
    end

    test "a waiting run asks its question in the bar, labelled, with how many follow", %{
      conn: conn,
      project: project
    } do
      run = run_fixture(project, "shop-61", %{status: :waiting_for_input})
      {:ok, _} = Runs.upsert_question(run.id, "q1", "Which way?")
      {:ok, _} = Runs.upsert_question(run.id, "q2", "And then?")

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
      assert has_element?(view, "#run-status[data-status=waiting_for_input]")
      assert has_element?(view, "#abort")
      refute has_element?(view, "#retry")
      assert has_element?(view, "#prompt-bar #question-q1", "The agent asks")
      assert has_element?(view, "#answer-q1 label[for=answer-q1-text]", "Which way?")
      assert has_element?(view, "#questions-more", "1 more after this")
      refute has_element?(view, "#prompt")
    end

    test "sends a message to the agent while it works", %{conn: conn, project: project} do
      {:ok, _} = Coordinator.enqueue(project, "shop-4", snapshot("shop-4", "Work [fake:hang]"))
      assert_receive {:run_updated, %{id: "shop-4-1", status: :running}}, 10_000
      {:ok, view, _html} = live(conn, ~p"/runs/shop-4-1")

      view |> form("#prompt", %{"text" => "Use tabs"}) |> render_submit()
      assert_push_event(view, "prompt:sent", %{id: "prompt"})

      # It waits in the agent's inbox until the agent reads it; then it is part of the transcript.
      eventually(fn -> assert has_element?(view, "#inbox #inbox-3", "Use tabs") end)

      agent_event("shop-4-1", 1, "head", %{
        "type" => "update",
        "entries" => [prompt_entry(9, "Use tabs")],
        "live" => live_state(%{"busy" => true})
      })

      eventually(fn -> refute has_element?(view, "#inbox") end)
      assert has_element?(view, "#items-ev-1-e-9 [data-from=input]", "Use tabs")

      Coordinator.abort("shop-4-1")
      assert_receive {:run_updated, %{id: "shop-4-1", status: :failed}}, 5_000
    end

    test "the message field is disabled until the run is running", %{conn: conn, project: project} do
      run = run_fixture(project, "shop-63", %{status: :picked_up})
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
      assert has_element?(view, "#prompt textarea[disabled]")
      assert has_element?(view, "#prompt-stop")
      refute has_element?(view, "#prompt-submit")
    end

    test "review feedback resumes the same run and merging removes its prompt", %{
      conn: conn,
      project: project
    } do
      {:ok, run} = Coordinator.enqueue(project, "shop-81", snapshot("shop-81"))
      assert_receive {:run_updated, %{id: "shop-81-1", status: :completed}}, 10_000
      {:ok, view, _} = live(conn, ~p"/runs/#{run.id}")
      assert has_element?(view, "#run-status[data-status=completed]", "In review")
      assert has_element?(view, "#prompt textarea:not([disabled])")
      refute has_element?(view, "#abort")

      view |> form("#prompt", %{"text" => "Please address the review"}) |> render_submit()
      assert_push_event(view, "prompt:sent", %{id: "prompt"})
      assert has_element?(view, "#run-status[data-status=running]", "In progress")
      assert has_element?(view, "#abort")
      assert Runs.get_run!(run.id).attempt == 1

      Conductor.Runner.call(%{type: "fake_settle", run_id: run.id, outcome: "completed"})
      assert_receive {:run_updated, %{id: "shop-81-1", status: :completed}}, 5_000
      stub_github(pr_state: "closed", pr_merged: true)
      assert :ok = Conductor.Poller.poll()
      assert has_element?(view, "#run-status[data-status=merged]", "Done")
      assert has_element?(view, "#tab-1[data-state=done]")
      refute has_element?(view, "#prompt-bar")
      refute has_element?(view, "#abort")

      {:ok, view, _} = live(conn, ~p"/runs/#{run.id}")
      refute has_element?(view, "#prompt-bar")
    end
  end

  describe "page frame" do
    test "a running run: breadcrumb, status line, actions, details and the message field", %{
      conn: conn,
      project: project
    } do
      run =
        run_fixture(project, "shop-5", %{
          status: :running,
          branch: "conductor/shop-5",
          workspace_path: "/tmp/ws/shop-5",
          issue_snapshot:
            snapshot("shop-5", "Add a limit", %{"url" => "https://github.com/acme/shop/issues/5"})
        })

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "a#run-back[href='/']", "Runs")
      assert has_element?(view, "#run-id", "shop-5-1")
      assert has_element?(view, "#run-summary", "Add a limit")
      assert has_element?(view, "#run-status[data-status=running]")
      assert has_element?(view, "#run-branch", "conductor/shop-5")
      assert has_element?(view, "#run-started", "started")
      assert has_element?(view, "a#open-issue[href='https://github.com/acme/shop/issues/5']")

      # Aborting a run that is still going asks first, in a dialog.
      assert has_element?(view, "#abort")
      assert has_element?(view, "dialog#confirm-abort #confirm-abort-confirm", "Abort")
      refute has_element?(view, "#retry")
      refute has_element?(view, "#run-error")

      assert has_element?(view, "#run-project", "acme/1")
      assert has_element?(view, "#run-repository", project.repo.name)
      assert has_element?(view, "#run-pr", "Not opened yet")
      refute has_element?(view, "#run-pr-link")
      assert has_element?(view, "#run-attempt", "1")
      refute has_element?(view, "#run-attempts a")
      assert has_element?(view, "#run-workspace", "/tmp/ws/shop-5")

      assert has_element?(view, "#prompt label[for=prompt-text]", "Message the head agent")
      assert has_element?(view, "#prompt textarea#prompt-text:not([disabled])")
      assert has_element?(view, "#prompt-hint", "Waits in the agent's inbox")
      assert has_element?(view, "#prompt-submit")
      assert has_element?(view, "#prompt-stop")
    end

    test "a run without an issue link or workspace says so", %{conn: conn, project: project} do
      run = run_fixture(project, "shop-6", %{status: :waiting_for_input})
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
      refute has_element?(view, "#open-issue")
      assert has_element?(view, "#run-workspace", "Not created yet")
    end

    test "a failed run that got to work offers Continue beside Retry", %{
      conn: conn,
      project: project
    } do
      never_ran = run_fixture(project, "shop-30", %{status: :failed, error: "no workspace"})
      {:ok, view, _html} = live(conn, ~p"/runs/#{never_ran.id}")
      refute has_element?(view, "#continue")

      models = %{"head" => %{"provider" => "faux", "modelId" => "faux-1"}}
      ran = run_fixture(project, "shop-31", %{status: :running, models: models})
      {:ok, failed} = Runs.fail(ran, %{error: "model_error: provider overloaded"})
      {:ok, view, _html} = live(conn, ~p"/runs/#{failed.id}")

      assert has_element?(view, "#retry")
      assert has_element?(view, "#continue-submit", "Continue")
      refute has_element?(view, "#continue textarea[required]")

      # Without its workspace the run cannot go on; saying so leaves it as it was.
      view |> form("#continue", %{"text" => ""}) |> render_submit()
      assert render(view) =~ "The original workspace is unavailable"
      assert has_element?(view, "#run-status[data-status=failed]")
    end

    test "a failed run: the error banner, Retry, and the other attempts", %{
      conn: conn,
      project: project
    } do
      first = run_fixture(project, "shop-7", %{status: :failed, error: "boom"})

      second =
        run_fixture(project, "shop-7", %{status: :failed, error: "Tests failed.\nexit 2"})

      other_issue = run_fixture(project, "shop-8", %{status: :failed, error: "boom"})

      {:ok, view, _html} = live(conn, ~p"/runs/#{second.id}")

      assert has_element?(view, "#run-status[data-status=failed]")
      assert has_element?(view, "#run-error[role=alert]")
      # Line breaks are kept.
      assert view |> element("#run-error-text") |> render() =~ "Tests failed.\nexit 2"
      assert has_element?(view, "#retry")
      refute has_element?(view, "#abort")
      refute has_element?(view, "#confirm-abort")
      refute has_element?(view, "#prompt-bar")
      assert has_element?(view, "#run-workspace", "Removed")

      assert has_element?(view, "#run-attempt", "2")
      assert has_element?(view, "#attempt-#{first.id} a[href='/runs/#{first.id}']", first.id)
      assert has_element?(view, "#attempt-#{first.id} [data-status=failed]", "Failed")
      refute has_element?(view, "#attempt-#{second.id}")
      refute has_element?(view, "#attempt-#{other_issue.id}")

      {:ok, earlier, _} = live(conn, ~p"/runs/#{first.id}")
      refute has_element?(earlier, "#retry")

      # A retry is another attempt, listed as soon as it is there.
      {:ok, third} = Runs.create_run(project, "shop-7", snapshot("shop-7"))

      eventually(fn ->
        assert has_element?(view, "#attempt-#{third.id} [data-status=picked_up]")
        refute has_element?(view, "#retry")
      end)
    end

    test "a completed run links its pull request from the details and offers no retry", %{
      conn: conn,
      project: project
    } do
      run =
        run_fixture(project, "shop-9", %{
          status: :completed,
          pr_url: "https://github.com/acme/shop/pull/221"
        })

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(
               view,
               "a#run-pr-link[href='https://github.com/acme/shop/pull/221']",
               "#221"
             )

      refute has_element?(view, "#retry")
      refute has_element?(view, "#abort")
    end

    test "shadow audit shows suggestions alongside unchanged chosen routing", %{
      conn: conn,
      project: project
    } do
      issue =
        snapshot("shop-91", "Root", %{
          "subtasks" => [snapshot("shop-92"), snapshot("shop-93", "Small", %{"size" => "S"})]
        })

      {:ok, run} = Runs.create_run(project, "shop-91", issue)
      {:ok, run} = Runs.pump(run)
      models = Map.new(~w(head low medium high), &{&1, %{"provider" => "test", "modelId" => &1}})
      {:ok, run} = Runs.provision_end(run, %{models: models})

      {:ok, _} =
        Conductor.Classification.persist(run, fn _, _ ->
          {:ok,
           %{
             "#92" => %{
               "status" => "suggested",
               "complexity" => "low",
               "reason" => "Tiny change",
               "provider" => "audit",
               "model" => "judge",
               "latency_ms" => 12
             }
           }}
        end)

      {:ok, view, _} = live(conn, ~p"/runs/#{run.id}")
      assert has_element?(view, "#classification-audit", "Suggestions do not change routing")
      assert has_element?(view, "[data-issue-key='#91']", "Chosen routing: head · test/head")
      assert has_element?(view, "[data-issue-key='#92']", "Chosen routing: high · test/high")
      assert has_element?(view, "[data-issue-key='#92']", "suggested · low")
      assert has_element?(view, "[data-issue-key='#92']", "Tiny change")
      assert has_element?(view, "[data-issue-key='#92']", "audit/judge")
      assert has_element?(view, "[data-issue-key='#93']", "Chosen routing: low · test/low")
      assert has_element?(view, "[data-issue-key='#93']", "explicit · low")
    end
  end

  describe "models" do
    defp answer(run, conversation, role, id, model) do
      message = %{
        "role" => "assistant",
        "provider" => "faux",
        "model" => model,
        "stopReason" => "stop",
        "content" => [%{"type" => "text", "text" => "Done."}]
      }

      entries(run.id, conversation, role, [
        %{"id" => id, "kind" => "pi.assistant", "model" => [message]}
      ])
    end

    test "the details name the head model and its reasoning level once it is chosen", %{
      conn: conn,
      project: project
    } do
      models = %{"head" => %{"provider" => "faux", "modelId" => "faux-1", "reasoning" => "high"}}
      run = run_fixture(project, "shop-20", %{status: :running, models: models})
      plain = %{"head" => %{"provider" => "faux", "modelId" => "faux-2"}}
      other = run_fixture(project, "shop-21", %{status: :running, models: plain})
      unprovisioned = run_fixture(project, "shop-22")

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
      assert has_element?(view, "#run-model-label", "Head model")
      assert has_element?(view, "#run-model-id", "faux/faux-1")
      assert has_element?(view, "#run-model-reasoning", "high")

      {:ok, view, _html} = live(conn, ~p"/runs/#{other.id}")
      assert has_element?(view, "#run-model-id", "faux/faux-2")
      refute has_element?(view, "#run-model-reasoning")

      {:ok, view, _html} = live(conn, ~p"/runs/#{unprovisioned.id}")
      assert has_element?(view, "#run-model", "Not chosen yet")
      refute has_element?(view, "#run-model-id")
    end

    test "a subagent's tab and the details name the model its conversation ran on", %{
      conn: conn,
      project: project
    } do
      models = %{"head" => %{"provider" => "faux", "modelId" => "faux-1"}}
      run = run_fixture(project, "shop-23", %{status: :running, models: models})
      answer(run, 1, "head", 1, "faux-1")
      answer(run, 2, "sub:#24", 1, "faux-small")

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
      assert has_element?(view, "#tab-2[title='Done · faux/faux-small']")
      assert has_element?(view, "#tab-1[title='Working']")
      assert has_element?(view, "#run-model-id", "faux/faux-1")

      view |> element("#tab-2") |> render_click()
      assert has_element?(view, "#run-model-label", "Model")
      assert has_element?(view, "#run-model-id", "faux/faux-small")

      # A subagent that starts while the page is open is named with its first answer.
      agent_event(run.id, 3, "sub:#25", %{
        "type" => "update",
        "live" => live_state(%{"busy" => true})
      })

      eventually(fn -> assert has_element?(view, "#tab-3[title=Working]") end)
      view |> element("#tab-3") |> render_click()
      assert has_element?(view, "#run-model", "Not known yet")

      answer(run, 3, "sub:#25", 1, "faux-large")
      eventually(fn -> assert has_element?(view, "#tab-3[title='Done · faux/faux-large']") end)
      assert has_element?(view, "#run-model-id", "faux/faux-large")

      view |> element("#tab-1") |> render_click()
      assert has_element?(view, "#run-model-label", "Head model")
      assert has_element?(view, "#run-model-id", "faux/faux-1")
    end
  end

  describe "conversation tabs" do
    defp entry(run, conversation, role, id, kind, stop \\ nil) do
      message = %{"role" => "assistant", "stopReason" => stop, "content" => []}
      entries(run.id, conversation, role, [%{"id" => id, "kind" => kind, "model" => [message]}])
    end

    test "each tab's state follows the run's status and how its conversation ended", %{
      conn: conn,
      project: project
    } do
      for {status, conversations, states} <- [
            {:running,
             [
               {"head", "pi.user", nil},
               {"sub:#12", "pi.assistant", "stop"},
               {"sub:#13", "pi.assistant", "toolUse"}
             ], ["working", "done", "working"]},
            {:waiting_for_input, [{"head", "pi.assistant", "toolUse"}], ["waiting"]},
            {:completed, [{"head", "pi.assistant", "stop"}, {"sub:#12", "pi.tool-result", nil}],
             ["review", "done"]},
            {:failed,
             [
               {"head", "pi.assistant", "stop"},
               {"sub:#12", "pi.assistant", "error"},
               {"sub:#13", "pi.assistant", "stop"}
             ], ["failed", "failed", "done"]},
            # Earlier attempts of a subagent are over; one that ended in an error failed.
            {:running,
             [
               {"head", "pi.user", nil},
               {"sub:#12", "pi.tool-result", nil},
               {"sub:#12", "pi.assistant", "error"},
               {"sub:#12", "pi.tool-result", nil}
             ], ["working", "done", "failed", "working"]}
          ] do
        run =
          run_fixture(project, "shop-#{System.unique_integer([:positive])}", %{status: status})

        for {{role, kind, stop}, n} <- Enum.with_index(conversations, 1),
            do: entry(run, n, role, 1, kind, stop)

        {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

        for {state, n} <- Enum.with_index(states, 1) do
          assert has_element?(view, "#tab-#{n}[data-state=#{state}]"), "#{status} tab-#{n}"
          assert has_element?(view, "#tab-#{n} [data-pulse]") == (state == "working")
        end
      end
    end

    test "the states change with the events and the run's status", %{conn: conn, project: project} do
      run = run_fixture(project, "shop-45", %{status: :running})
      entry(run, 1, "head", 1, "pi.user")
      entry(run, 2, "sub:#12", 1, "pi.user")

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
      assert has_element?(view, "#tab-2[data-state=working]")

      entry(run, 2, "sub:#12", 2, "pi.assistant", "stop")
      eventually(fn -> assert has_element?(view, "#tab-2[data-state=done]") end)

      agent_event(run.id, 2, "sub:#12", %{
        "type" => "update",
        "live" => live_state(%{"busy" => true})
      })

      eventually(fn -> assert has_element?(view, "#tab-2[data-state=working]") end)
      entry(run, 2, "sub:#12", 3, "pi.assistant", "error")
      eventually(fn -> assert has_element?(view, "#tab-2[data-state=failed]") end)

      {:ok, _run} = Runs.wait_for_input(run)
      eventually(fn -> assert has_element?(view, "#tab-1[data-state=waiting]") end)
    end
  end

  describe "status history" do
    test "the timeline lists every status the run has had, and grows as it changes", %{
      conn: conn,
      project: project
    } do
      run = run_fixture(project, "shop-30", %{status: :running})
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      entry = &"#run-timeline-entries > li:nth-child(#{&1})[data-status=#{&2}]"
      assert has_element?(view, entry.(1, :picked_up), "Picked up")
      assert has_element?(view, entry.(2, :provisioning), "Provisioning")
      assert has_element?(view, entry.(3, :running) <> ":last-child time[datetime]")
      refute has_element?(view, "#run-failed-line")

      {:ok, _waiting} = Runs.wait_for_input(run)

      eventually(fn ->
        assert has_element?(
                 view,
                 entry.(4, :waiting_for_input) <> ":last-child",
                 "Waiting for input"
               )
      end)

      {:ok, _failed} = Runs.fail(Runs.get_run!(run.id), %{error: "boom"})

      eventually(fn ->
        assert has_element?(view, entry.(5, :failed) <> ":last-child", "Failed")
        assert has_element?(view, "#run-failed-line time[datetime]")
      end)
    end

    test "the head conversation of a failed run ends with the status change", %{
      conn: conn,
      project: project
    } do
      run = run_fixture(project, "shop-31", %{status: :running})

      for {conversation, role} <- [{1, "head"}, {2, "sub:#12"}],
          do:
            entries(run.id, conversation, role, [
              %{"id" => 1, "kind" => "pi.assistant", "content" => []}
            ])

      {:ok, _failed} = Runs.fail(run, %{error: "boom"})
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#transcript + #run-failed-line", "status → failed ·")
      view |> element("#tab-2") |> render_click()
      refute has_element?(view, "#run-failed-line")
      view |> element("#tab-1") |> render_click()
      assert has_element?(view, "#run-failed-line")
    end
  end
end
