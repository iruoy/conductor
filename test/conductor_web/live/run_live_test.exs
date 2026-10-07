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

  test "shows the transcript and sends answers to the runner", %{conn: conn, project: project} do
    {:ok, _} = Coordinator.enqueue(project, "shop-2", snapshot("shop-2", "Ask [fake:ask]"))
    assert_receive {:run_updated, %{id: "shop-2-1", status: :waiting_for_input}}, 10_000

    {:ok, view, html} = live(conn, ~p"/runs/shop-2-1")
    assert html =~ "<h1>#2: Ask [fake:ask]</h1>"
    assert html =~ "Which way?"

    # The prompt under the transcript answers the open question.
    assert has_element?(view, "form#answer-q1[phx-hook] #question-q1", "Which way?")
    assert has_element?(view, "#answer-q1 textarea:not([disabled])")
    assert has_element?(view, "#answer-q1-submit")

    view |> form("#answer-q1", %{"text" => "left"}) |> render_submit()
    assert_receive {:run_updated, %{id: "shop-2-1", status: :completed}}, 5_000
    eventually(fn -> assert render(view) =~ "Did it." end)
    refute render(view) =~ "Which way?"
    # The run is over: there is nothing left to say or stop.
    refute has_element?(view, "form[phx-hook]")
    assert [%{answer: "left"}] = Runs.list_questions("shop-2-1")
  end

  test "sends a message to the agent while it works", %{conn: conn, project: project} do
    {:ok, _} = Coordinator.enqueue(project, "shop-4", snapshot("shop-4", "Work [fake:hang]"))
    assert_receive {:run_updated, %{id: "shop-4-1", status: :running}}, 10_000
    {:ok, view, _html} = live(conn, ~p"/runs/shop-4-1")

    view |> form("#prompt", %{"text" => "Use tabs"}) |> render_submit()
    assert_push_event(view, "prompt:sent", %{id: "prompt"})

    # It waits in the agent's inbox until the agent reads it; then it is part of the transcript.
    eventually(fn -> assert has_element?(view, "#inbox #inbox-3", "Use tabs") end)

    agent = %{
      "type" => "agent_event",
      "run_id" => "shop-4-1",
      "conversation" => 1,
      "role" => "head"
    }

    Runs.ingest(Map.put(agent, "event", %{"type" => "inbox_update", "items" => []}))

    user = %{
      "id" => 9,
      "kind" => "pi.user",
      "model" => [%{"role" => "user", "content" => "Use tabs"}]
    }

    Runs.ingest(Map.put(agent, "event", %{"type" => "message_end", "entry" => user}))

    eventually(fn -> refute has_element?(view, "#inbox") end)
    assert has_element?(view, "#items-ev-1-e-9 [data-from=input]", "Use tabs")

    Coordinator.abort("shop-4-1")
    assert_receive {:run_updated, %{id: "shop-4-1", status: :failed}}, 5_000
  end

  test "folds a finished turn into one row before its answer", %{conn: conn, project: project} do
    run = run_fixture(project, "shop-5", %{status: :running})
    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    send_entry = fn id, kind, message ->
      Runs.ingest(%{
        "type" => "agent_event",
        "run_id" => run.id,
        "conversation" => 4,
        "role" => "head",
        "event" => %{
          "type" => "message_end",
          "entry" => %{"id" => id, "kind" => kind, "model" => [message]}
        }
      })
    end

    call = %{
      "type" => "toolCall",
      "id" => "t1",
      "name" => "bash",
      "arguments" => %{"command" => "ls"}
    }

    looking = %{"type" => "text", "text" => "Looking around."}

    result = %{
      "role" => "toolResult",
      "toolCallId" => "t1",
      "toolName" => "bash",
      "content" => "a.ex"
    }

    answer = %{"type" => "text", "text" => "It is there."}

    send_entry.(1, "pi.user", %{"role" => "user", "content" => "Find it", "timestamp" => 1_000})
    send_entry.(2, "pi.assistant", %{"content" => [looking, call], "stopReason" => "toolUse"})
    send_entry.(3, "pi.tool-result", result)

    # While the turn goes on, everything shows.
    assert has_element?(
             view,
             "#items-ev-4-e-2-0[data-from=agent], #items-ev-4-e-2-0 [data-from=agent]"
           )

    assert has_element?(view, "#items-ev-4-e-2-1")
    refute has_element?(view, "[data-work]")

    stop = %{"content" => [answer], "stopReason" => "stop", "timestamp" => 126_000}
    send_entry.(4, "pi.assistant", stop)

    folded = "#items-ev-4-e-2-0-work > details:not([open])"
    assert has_element?(view, folded <> " > summary [data-row-text]", "Ran 1 command")
    assert has_element?(view, folded <> " > summary [data-row-meta]", "2m 5s")
    assert has_element?(view, folded <> " [data-work] [data-from=agent]", "Looking around.")
    assert has_element?(view, folded <> " [data-work] [data-tool=bash]", "a.ex")
    refute has_element?(view, "#items-ev-4-e-2-0")
    refute has_element?(view, "#items-ev-4-e-2-1")
    assert has_element?(view, "#items-ev-4-e-4-0 [data-from=agent]", "It is there.")

    # The same shows after a reload.
    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
    assert has_element?(view, folded <> " > summary [data-row-meta]", "2m 5s")
    assert has_element?(view, folded <> " [data-work] [data-from=agent]", "Looking around.")
    assert has_element?(view, "#items-ev-4-e-4-0 [data-from=agent]", "It is there.")
  end

  test "shows the first prompt that arrives while the page is open as the issue", %{
    conn: conn,
    project: project
  } do
    run = run_fixture(project, "shop-15", %{status: :running})
    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    prompt = fn conversation, id, text ->
      Runs.ingest(%{
        "type" => "agent_event",
        "run_id" => run.id,
        "conversation" => conversation,
        "role" => if(conversation == 4, do: "head", else: "sub:#16"),
        "event" => %{
          "type" => "message_end",
          "entry" => %{
            "id" => id,
            "kind" => "pi.user",
            "model" => [%{"role" => "user", "content" => text}]
          }
        }
      })
    end

    prompt.(4, 1, "The issue")
    prompt.(4, 2, "Use tabs")

    eventually(fn -> assert has_element?(view, "#items-ev-4-e-2") end)
    assert has_element?(view, "#items-ev-4-e-1 [data-badge]", "IS")
    assert has_element?(view, "#items-ev-4-e-1 [data-label]", "Issue")
    assert has_element?(view, "#items-ev-4-e-2 [data-badge]", "YOU")
    assert has_element?(view, "#items-ev-4-e-2 [data-label]", "You")

    # Another conversation starts with a first prompt of its own, also when it is opened before it has one.
    prompt.(5, 1, "The subtask")
    eventually(fn -> assert has_element?(view, "#tab-5") end)
    view |> element("#tab-5") |> render_click()
    assert has_element?(view, "#items-ev-5-e-1 [data-label]", "Issue")
    prompt.(5, 2, "Go on")
    eventually(fn -> assert has_element?(view, "#items-ev-5-e-2 [data-label]", "You") end)

    # A page that loads the transcript marks the same one.
    view |> element("#tab-4") |> render_click()
    assert has_element?(view, "#items-ev-4-e-1 [data-label]", "Issue")
    assert has_element?(view, "#items-ev-4-e-2 [data-label]", "You")
  end

  test "streams live text and tool output", %{conn: conn, project: project} do
    run = run_fixture(project, "shop-3", %{status: :running})
    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    send_event = fn event ->
      Runs.ingest(%{
        "type" => "agent_event",
        "run_id" => run.id,
        "conversation" => 4,
        "role" => "head",
        "event" => event
      })
    end

    send_event.(%{"type" => "message_start", "message" => %{"role" => "assistant"}})

    # Nothing has come in yet: the agent is at work.
    assert has_element?(view, "#indicator .loading")

    # Thinking shows as it streams in, and becomes a closed line when the text starts.
    send_event.(%{
      "type" => "message_update",
      "changes" => [%{"type" => "thinking_delta", "delta" => "Let me see"}]
    })

    assert has_element?(view, "#live-thinking[data-thinking]", "Thinking")
    assert has_element?(view, "#live-thinking", "Let me see")
    refute has_element?(view, "#indicator")

    send_event.(%{
      "type" => "message_update",
      "changes" => [%{"type" => "text_delta", "delta" => "Thinking out loud"}]
    })

    # While the agent works the prompt takes a message for it and offers to stop it.
    assert has_element?(view, "#prompt textarea:not([disabled])")
    assert has_element?(view, "#prompt-stop")
    assert has_element?(view, "#prompt-submit")

    # Aborting a run that is still going asks first, in a dialog.
    assert has_element?(view, "dialog#confirm-abort #confirm-abort-confirm", "Abort")

    assert render(view) =~ "Thinking out loud"

    # Markdown is rendered, and HTML in it is shown as text.
    send_event.(%{
      "type" => "message_update",
      "changes" => [%{"type" => "text_delta", "delta" => " in **bold** <script>x</script>"}]
    })

    assert has_element?(view, "#live [data-from=agent] .prose strong", "bold")
    assert has_element?(view, "details#live-thinking:not([open])", "Thought")

    # The transcript and what streams in share one scroller, which offers a way back to the end.
    assert has_element?(view, "#transcript-scroller[phx-hook] [role=log] #transcript")
    assert has_element?(view, "#transcript-scroller [role=log] #live")
    assert has_element?(view, "#transcript-scroller button[data-scroller-button][inert]")
    refute has_element?(view, "#live script")

    send_event.(%{
      "type" => "tool_execution_start",
      "toolCallId" => "t1",
      "toolName" => "bash",
      "args" => %{"command" => "mix test"}
    })

    send_event.(%{
      "type" => "tool_execution_update",
      "toolCallId" => "t1",
      "toolName" => "bash",
      "output" => %{"set" => "3 tests, 0 failures"}
    })

    assert has_element?(
             view,
             "#live-tool-t1[data-tool=bash] [data-tool-status=running]",
             "running"
           )

    assert has_element?(view, "#live-tool-t1", "3 tests, 0 failures")
    assert has_element?(view, "#tab-4", "head")

    # Once the result is in, it shows on the tool call, also after a reload.
    call = %{"type" => "toolCall", "id" => "t1", "name" => "bash", "arguments" => %{}}
    result = %{"role" => "toolResult", "toolCallId" => "t1", "toolName" => "bash"}
    result = Map.put(result, "content", [%{"type" => "text", "text" => "all green"}])

    for {id, kind, message} <- [
          {1, "pi.assistant", %{"content" => [call], "stopReason" => "toolUse"}},
          {2, "pi.tool-result", result}
        ] do
      entry = %{"id" => id, "kind" => kind, "model" => [message]}
      send_event.(%{"type" => "message_end", "entry" => entry})
    end

    assert has_element?(view, "#items-ev-4-e-1-0 [data-tool=bash]", "all green")
    refute has_element?(view, "#items-ev-4-e-2")

    # What the agent does between two texts is one group of steps, which says what goes on while it works.
    thought = %{"type" => "thinking", "thinking" => "So it works."}
    again = %{"type" => "toolCall", "id" => "t2", "name" => "bash", "arguments" => %{}}
    message = %{"content" => [thought, again], "stopReason" => "toolUse"}
    entry = %{"id" => 4, "kind" => "pi.assistant", "model" => [message]}
    send_event.(%{"type" => "message_end", "entry" => entry})

    summary = "#items-ev-4-e-1-0 > details:not([open]) > summary"
    assert has_element?(view, summary <> " [data-row-text]", "Running commands")
    assert has_element?(view, summary <> " > [data-pulse]")

    assert has_element?(view, "#items-ev-4-e-1-0 [data-steps] [data-tool=bash]", "all green")
    assert has_element?(view, "#items-ev-4-e-1-0 [data-steps] details", "So it works.")
    # The call without a result is the one that runs.
    assert has_element?(
             view,
             "#items-ev-4-e-1-0 [data-steps] [data-tool-status=running]",
             "running"
           )

    refute has_element?(view, "#items-ev-4-e-4-0")

    # The agent goes on after a tool result, until a message that calls no tool; that closes the group.
    send_event.(%{"type" => "tool_execution_end", "toolCallId" => "t1"})
    refute has_element?(view, "#indicator")
    done = %{"content" => [%{"type" => "text", "text" => "Done."}], "stopReason" => "stop"}
    entry = %{"id" => 5, "kind" => "pi.assistant", "model" => [done]}
    send_event.(%{"type" => "message_end", "entry" => entry})
    assert has_element?(view, summary <> " [data-row-text]", "Thought, ran 2 commands")
    refute has_element?(view, summary <> " > [data-pulse]")

    assert has_element?(
             view,
             "#items-ev-4-e-5-0[data-from=agent], #items-ev-4-e-5-0 [data-from=agent]"
           )

    # An edit shows what it changed, not what the tool answered.
    edit = %{"type" => "toolCall", "id" => "t3", "name" => "edit"}
    edit = Map.put(edit, "arguments", %{"path" => "lib/a.ex", "edits" => []})
    message = %{"content" => [edit], "stopReason" => "toolUse"}
    entry = %{"id" => 6, "kind" => "pi.assistant", "model" => [message]}
    send_event.(%{"type" => "message_end", "entry" => entry})

    result = %{"role" => "toolResult", "toolCallId" => "t3", "toolName" => "edit"}
    result = Map.put(result, "content", [%{"type" => "text", "text" => "Replaced 1 block"}])
    diff = "  1 same\n- 2 old\n+ 2 new\n+ 3 more\n  3 rest"
    result = Map.put(result, "details", %{"diff" => diff})
    entry = %{"id" => 7, "kind" => "pi.tool-result", "model" => [result]}
    send_event.(%{"type" => "message_end", "entry" => entry})

    assert has_element?(view, "#items-ev-4-e-6-0 [data-tool=edit] [data-tool-call]", "lib/a.ex")
    # Each line has its number in the old file and in the new one.
    lines =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#items-ev-4-e-6-0 [data-diff] > span")
      |> Enum.map(fn line ->
        {line |> LazyHTML.query("[data-old]") |> LazyHTML.text(),
         line |> LazyHTML.query("[data-new]") |> LazyHTML.text()}
      end)

    assert lines == [{"1", "1"}, {"2", ""}, {"", "2"}, {"", "3"}, {"3", "4"}]
    assert has_element?(view, "#items-ev-4-e-6-0 [data-diff] .text-success", "new")
    assert has_element?(view, "#items-ev-4-e-6-0 [data-diff] .text-error", "old")
    refute render(view) =~ "Replaced 1 block"

    # The same shows after a reload.
    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
    assert has_element?(view, summary <> " [data-row-text]", "Thought, ran 2 commands")
    assert has_element?(view, "#items-ev-4-e-1-0 [data-steps] [data-tool=bash]", "all green")
    refute has_element?(view, "#items-ev-4-e-2")
    refute has_element?(view, "#items-ev-4-e-4-0")
  end

  describe "page frame" do
    test "a running run: breadcrumb, status line, actions and details", %{
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

      assert has_element?(view, "#run #run-header a#run-back[href='/']", "Runs")
      assert has_element?(view, "h1#run-title #run-id", "shop-5-1")
      assert has_element?(view, "h1#run-title #run-summary", "Add a limit")
      assert has_element?(view, "#run-status[data-status=running]")
      assert has_element?(view, "#run-branch", "conductor/shop-5")
      assert has_element?(view, "#run-started", "started")

      assert has_element?(
               view,
               "a#open-issue[href='https://github.com/acme/shop/issues/5'][target=_blank]"
             )

      assert has_element?(view, "#abort")
      assert has_element?(view, "dialog#confirm-abort")
      refute has_element?(view, "#retry")
      refute has_element?(view, "#run-error")

      assert has_element?(view, "#run-sidebar dl#run-details #run-project", "acme/1")
      assert has_element?(view, "#run-repository", project.repo.name)
      assert has_element?(view, "#run-pr", "Not opened yet")
      refute has_element?(view, "#run-pr-link")
      assert has_element?(view, "#run-attempt", "1")
      refute has_element?(view, "#run-attempts a")
      assert has_element?(view, "#run-workspace", "/tmp/ws/shop-5")

      # The transcript scrolls in its own frame, with the prompt under it.
      assert has_element?(view, "#run #transcript-scroller[phx-hook] #transcript")
      assert has_element?(view, "#run #prompt-bar form#prompt")
    end

    test "a waiting run: the warning chip, and the question in the bar at the bottom", %{
      conn: conn,
      project: project
    } do
      run = run_fixture(project, "shop-6", %{status: :waiting_for_input})
      {:ok, _question} = Runs.upsert_question(run.id, "q1", "Which way?")

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#run-status[data-status=waiting_for_input]")
      assert has_element?(view, "#abort")
      refute has_element?(view, "#retry")
      # The snapshot has no link to the issue, and the workspace is not there yet.
      refute has_element?(view, "#open-issue")
      assert has_element?(view, "#run-workspace", "Not created yet")
      assert has_element?(view, "#prompt-bar form#answer-q1 #question-q1", "Which way?")
    end

    test "a failed run: the error banner, Retry, the pull request and the other attempts", %{
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

      assert has_element?(
               view,
               "#run-attempts #attempt-#{first.id} a[href='/runs/#{first.id}']",
               first.id
             )

      assert has_element?(view, "#attempt-#{first.id} [data-status=failed]", "failed")
      refute has_element?(view, "#attempt-#{second.id}")
      refute has_element?(view, "#attempt-#{other_issue.id}")

      # A retry is another attempt, listed as soon as it is there.
      {:ok, third} = Runs.create_run(project, "shop-7", snapshot("shop-7"))

      eventually(fn ->
        assert has_element?(view, "#attempt-#{third.id} [data-status=picked_up]")
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
               "#run-pr a#run-pr-link[href='https://github.com/acme/shop/pull/221'][target=_blank]",
               "#221"
             )

      refute has_element?(view, "#run-header a[href*='/pull/']")
      refute has_element?(view, "#retry")
      refute has_element?(view, "#abort")
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

    test "the details name the head model, with the reasoning level that was set", %{
      conn: conn,
      project: project
    } do
      models = %{"head" => %{"provider" => "faux", "modelId" => "faux-1", "reasoning" => "high"}}
      run = run_fixture(project, "shop-20", %{status: :running, models: models})
      plain = %{"head" => %{"provider" => "faux", "modelId" => "faux-2"}}
      other = run_fixture(project, "shop-21", %{status: :running, models: plain})

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
      assert has_element?(view, "dl#run-details #run-model-label", "Head model")
      assert has_element?(view, "#run-model #run-model-id", "faux/faux-1")
      assert has_element?(view, "#run-model #run-model-reasoning", "high")

      {:ok, view, _html} = live(conn, ~p"/runs/#{other.id}")
      assert has_element?(view, "#run-model-id", "faux/faux-2")
      refute has_element?(view, "#run-model-reasoning")
    end

    test "a run from before the models were kept says so", %{conn: conn, project: project} do
      run = run_fixture(project, "shop-22", %{status: :running})

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
      assert has_element?(view, "#run-model-label", "Head model")
      assert has_element?(view, "#run-model", "Not recorded")
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
      assert has_element?(view, "#tab-2[title='faux/faux-small']")
      refute has_element?(view, "#tab-1[title]")
      assert has_element?(view, "#run-model-id", "faux/faux-1")

      view |> element("#tab-2") |> render_click()
      assert has_element?(view, "#run-model-label", "Model")
      assert has_element?(view, "#run-model-id", "faux/faux-small")

      # A subagent that starts while the page is open is named with its first answer.
      Runs.ingest(%{
        "type" => "agent_event",
        "run_id" => run.id,
        "conversation" => 3,
        "role" => "sub:#25",
        "event" => %{"type" => "message_start", "message" => %{"role" => "assistant"}}
      })

      eventually(fn -> assert has_element?(view, "#tab-3") end)
      refute has_element?(view, "#tab-3[title]")
      view |> element("#tab-3") |> render_click()
      assert has_element?(view, "#run-model", "Not known yet")

      answer(run, 3, "sub:#25", 1, "faux-large")
      eventually(fn -> assert has_element?(view, "#tab-3[title='faux/faux-large']") end)
      assert has_element?(view, "#run-model-id", "faux/faux-large")

      view |> element("#tab-1") |> render_click()
      assert has_element?(view, "#run-model-label", "Head model")
      assert has_element?(view, "#run-model-id", "faux/faux-1")
    end
  end

  describe "status history" do
    test "the sidebar lists every status the run has had, and grows as it changes", %{
      conn: conn,
      project: project
    } do
      run = run_fixture(project, "shop-30", %{status: :running})
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#run-sidebar #run-details + div + #run-timeline", "Timeline")
      entries = "#run-timeline-entries > li"
      assert has_element?(view, "#{entries}:nth-child(1)[data-status=picked_up]", "Picked up")

      assert has_element?(
               view,
               "#{entries}:nth-child(2)[data-status=provisioning]",
               "Provisioning"
             )

      assert has_element?(
               view,
               "#{entries}:nth-child(3)[data-status=running]:last-child",
               "Running"
             )

      assert has_element?(view, "#{entries}:nth-child(3) time[datetime]")
      refute has_element?(view, "#run-failed-line")

      {:ok, _waiting} = Runs.wait_for_input(run)

      eventually(fn ->
        assert has_element?(
                 view,
                 "#{entries}:nth-child(4)[data-status=waiting_for_input]:last-child",
                 "Waiting for input"
               )
      end)

      {:ok, _failed} = Runs.fail(Runs.get_run!(run.id), %{error: "boom"})

      eventually(fn ->
        assert has_element?(
                 view,
                 "#{entries}:nth-child(5)[data-status=failed]:last-child",
                 "Failed"
               )

        assert has_element?(view, "#run-failed-line time[datetime]")
      end)
    end

    test "the head conversation of a failed run ends with the status change", %{
      conn: conn,
      project: project
    } do
      run = run_fixture(project, "shop-31", %{status: :running})

      for {conversation, role} <- [{1, "head"}, {2, "sub:#12"}] do
        Runs.ingest(%{
          "type" => "agent_event",
          "run_id" => run.id,
          "conversation" => conversation,
          "role" => role,
          "event" => %{
            "type" => "message_end",
            "entry" => %{"id" => 1, "kind" => "pi.assistant", "content" => []}
          }
        })
      end

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
