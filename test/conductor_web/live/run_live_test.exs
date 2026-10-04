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
    assert_receive {:run_updated, %{id: "shop-2-1", status: "waiting_for_input"}}, 10_000

    {:ok, view, html} = live(conn, ~p"/runs/shop-2-1")
    assert html =~ "# #2: Ask [fake:ask]"
    assert html =~ "Which way?"

    view |> form("#answer-q1", %{"text" => "left"}) |> render_submit()
    assert_receive {:run_updated, %{id: "shop-2-1", status: "completed"}}, 5_000
    eventually(fn -> assert render(view) =~ "Did it." end)
    refute render(view) =~ "Which way?"
    assert [%{answer: "left"}] = Runs.list_questions("shop-2-1")
  end

  test "streams live text and tool output", %{conn: conn, project: project} do
    run = run_fixture(project, "shop-3", %{status: "running"})
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

    send_event.(%{
      "type" => "message_update",
      "changes" => [%{"type" => "text_delta", "delta" => "Thinking out loud"}]
    })

    assert render(view) =~ "Thinking out loud"

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

    assert render(view) =~ "3 tests, 0 failures"
    assert has_element?(view, "#tab-4", "head")

    # Once the result is in, it shows on the tool call, also after a reload.
    call = %{"type" => "toolCall", "id" => "t1", "name" => "bash", "arguments" => %{}}
    result = %{"role" => "toolResult", "toolCallId" => "t1", "toolName" => "bash"}
    result = Map.put(result, "content", [%{"type" => "text", "text" => "all green"}])

    for {id, kind, message} <- [
          {1, "pi.assistant", %{"content" => [call]}},
          {2, "pi.tool-result", result}
        ] do
      entry = %{"id" => id, "kind" => kind, "model" => [message]}
      send_event.(%{"type" => "message_end", "entry" => entry})
    end

    assert has_element?(view, "#items-ev-4-e-1 details", "all green")
    refute has_element?(view, "#items-ev-4-e-2")

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
    assert has_element?(view, "#items-ev-4-e-1 details", "all green")
    refute has_element?(view, "#items-ev-4-e-2")
  end
end
