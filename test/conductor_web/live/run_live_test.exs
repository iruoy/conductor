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
    assert has_element?(view, folded <> " > summary", "Worked for 2m 5s · 1 steps")
    assert has_element?(view, folded <> " [data-work] [data-from=agent]", "Looking around.")
    assert has_element?(view, folded <> " [data-work] details", "a.ex")
    refute has_element?(view, "#items-ev-4-e-2-0")
    refute has_element?(view, "#items-ev-4-e-2-1")
    assert has_element?(view, "#items-ev-4-e-4-0 [data-from=agent]", "It is there.")

    # The same shows after a reload.
    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
    assert has_element?(view, folded <> " > summary", "Worked for 2m 5s")
    assert has_element?(view, folded <> " [data-work] [data-from=agent]", "Looking around.")
    assert has_element?(view, "#items-ev-4-e-4-0 [data-from=agent]", "It is there.")
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

    # Thinking is open and shimmers for as long as it streams, and closes when the text starts.
    send_event.(%{
      "type" => "message_update",
      "changes" => [%{"type" => "thinking_delta", "delta" => "Let me see"}]
    })

    assert has_element?(view, "details#live-thinking[open] .skeleton-text", "Thinking…")
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

    assert has_element?(view, "details#live-tool-t1[open] .skeleton-text", "bash")
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

    assert has_element?(view, "#items-ev-4-e-1-0 details", "all green")
    refute has_element?(view, "#items-ev-4-e-2")

    # What the agent does between two texts is one group of steps, which says what goes on while it works.
    thought = %{"type" => "thinking", "thinking" => "So it works."}
    again = %{"type" => "toolCall", "id" => "t2", "name" => "bash", "arguments" => %{}}
    message = %{"content" => [thought, again], "stopReason" => "toolUse"}
    entry = %{"id" => 4, "kind" => "pi.assistant", "model" => [message]}
    send_event.(%{"type" => "message_end", "entry" => entry})

    assert has_element?(view, "#items-ev-4-e-1-0 > details:not([open]) > summary", "3 steps")

    assert has_element?(
             view,
             "#items-ev-4-e-1-0 > details > summary .skeleton-text",
             "Running commands"
           )

    assert has_element?(view, "#items-ev-4-e-1-0 [data-steps] details", "all green")
    assert has_element?(view, "#items-ev-4-e-1-0 [data-steps] details", "So it works.")
    # The call without a result is the one that runs.
    assert has_element?(view, "#items-ev-4-e-1-0 [data-steps] .skeleton-text", "bash")
    refute has_element?(view, "#items-ev-4-e-4-0")

    # The agent goes on after a tool result, until a message that calls no tool; that closes the group.
    send_event.(%{"type" => "tool_execution_end", "toolCallId" => "t1"})
    refute has_element?(view, "#indicator")
    done = %{"content" => [%{"type" => "text", "text" => "Done."}], "stopReason" => "stop"}
    entry = %{"id" => 5, "kind" => "pi.assistant", "model" => [done]}
    send_event.(%{"type" => "message_end", "entry" => entry})
    assert has_element?(view, "#items-ev-4-e-1-0 > details > summary", "Ran commands")
    refute has_element?(view, "#items-ev-4-e-1-0 > details > summary .skeleton-text")

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

    assert has_element?(view, "#items-ev-4-e-6-0 summary", "lib/a.ex")
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
    assert has_element?(view, "#items-ev-4-e-1-0 > details:not([open]) > summary", "3 steps")
    assert has_element?(view, "#items-ev-4-e-1-0 [data-steps] details", "all green")
    refute has_element?(view, "#items-ev-4-e-2")
    refute has_element?(view, "#items-ev-4-e-4-0")
  end
end
