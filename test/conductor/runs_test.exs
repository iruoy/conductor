defmodule Conductor.RunsTest do
  use Conductor.DataCase, async: true
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
