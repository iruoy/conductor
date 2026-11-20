defmodule ConductorWeb.RunComponentsTest do
  use ExUnit.Case, async: true
  import ConductorWeb.RunComponents
  import Phoenix.LiveViewTest, only: [render_component: 2]

  describe "tool boxes" do
    test "each scroll box is a named keyboard stop, and only output is hooked for scrolling" do
      for {attrs, labels} <- [
            {[name: "bash", args: %{"command" => "echo one\necho two"}, output: "one\ntwo"],
             ["bash tool call", "bash output"]},
            {[name: "write", args: %{"path" => "file", "content" => "contents"}],
             ["Written file content"]},
            {[name: "edit", args: %{"path" => "file"}, diff: "-1 old\n+1 new", output: "ok"],
             ["edit diff"]}
          ] do
        html = render_component(&tool/1, [id: "tool"] ++ attrs)
        blocks = find(html, "pre")
        assert Enum.count(blocks) == length(labels)

        for label <- labels do
          assert found?(html, "pre[tabindex='0'][role='group'][aria-label='#{label}']")
        end

        refute found?(html, "[role='region']")
        refute found?(html, "pre:not([data-tool-output])[phx-hook]")
      end
    end

    test "streaming and finished output keep one stable hooked box that LiveView patches" do
      for state <- [[streaming: true], [done: true, exit_code: 0]] do
        html =
          render_component(&tool/1, [id: "live-tool-t1", name: "bash", output: "a\nb"] ++ state)

        assert found?(
                 html,
                 "#live-tool-t1 > pre#live-tool-t1-output[data-tool-output][phx-hook='ToolOutputScroller']"
               )

        assert Enum.count(find(html, "[phx-hook]")) == 1
        refute found?(html, "[phx-update='ignore']")
      end
    end

    test "the hook mounts only once there is output and an id to hang it on" do
      refute found?(
               render_component(&tool/1, id: "t", name: "bash", streaming: true),
               "[phx-hook]"
             )

      html = render_component(&tool/1, name: "bash", output: "anonymous output")
      assert text(html, "pre[data-tool-output]") == "anonymous output"
      refute found?(html, "[phx-hook]")
    end

    test "transcript calls and orphan results get distinct stable output ids" do
      html =
        show(
          steps([
            call("t1", "bash", %{"command" => "echo one"}, result("bash", "one")),
            call("t2", "bash", %{"command" => "echo two"}, result("bash", "two"))
          ])
        )

      assert found?(html, "pre#tool-t1-output[phx-hook='ToolOutputScroller']")
      assert found?(html, "pre#tool-t2-output[phx-hook='ToolOutputScroller']")

      failed = result("bash", "boom", error: "Command exited with code 1")
      html = show(%{id: "r", kind: "pi.tool-result", payload: failed})
      assert found?(html, "pre#r-tool-result-output[phx-hook='ToolOutputScroller']")
      assert text(html, "[data-tool='bash result'] [data-tool-status=error]") == "exit 1"
    end

    test "untrusted commands, file contents, output and diffs stay literal text" do
      literal = "\e[31m<script>literal & \"quoted\"</script>\e[0m\n[1m[30m[46m café 🐈"

      for {attrs, selector} <- [
            {[name: "bash", args: %{"command" => literal}, output: "ok"],
             "pre[aria-label='bash tool call']"},
            {[name: "write", args: %{"path" => "file", "content" => literal}, output: "ok"],
             "pre[aria-label='Written file content']"},
            {[name: "bash", output: literal, streaming: true], "#tool-output"}
          ] do
        html = render_component(&tool/1, [id: "tool"] ++ attrs)
        assert LazyHTML.text(find(html, selector)) == literal
        refute found?(html, selector <> " *")
        refute found?(html, "script")
      end

      svg = "<svg onload='alert(1)'> & café"
      html = render_component(&tool/1, id: "tool", name: "edit", diff: "-1 #{svg}\n+1 #{svg}")
      assert LazyHTML.text(find(html, "[data-diff] > .gd")) =~ svg
      assert LazyHTML.text(find(html, "[data-diff] > .gi")) =~ svg
      refute found?(html, "svg")
    end
  end

  describe "transcript tools" do
    test "the status a tool shows follows its result" do
      open = call("t1", "bash", %{"command" => "mix test"})
      bash = &call("t1", "bash", %{"command" => "mix test"}, &1)
      read = &call("t1", "read", %{"path" => "a.ex"}, &1)

      for {group, status} <- [
            {steps([bash.(result("bash", "6 tests, 0 failures"))]), {"ok", "exit 0"}},
            {steps([bash.(result("bash", "", error: "Command exited with code 2"))]),
             {"error", "exit 2"}},
            {steps([bash.(result("bash", "", error: "Command timed out after 30 seconds"))]),
             {"error", "failed"}},
            {steps([read.(result("read", "defmodule A"))]), {"ok", "done"}},
            {steps([read.(result("read", "", error: "ENOENT"))]), {"error", "failed"}},
            {steps([open], true), {"running", "running"}},
            {steps([open]), nil}
          ] do
        html = show(group)

        case status do
          {state, label} -> assert text(html, "[data-tool-status=#{state}]") == label
          nil -> refute found?(html, "[data-tool-status]")
        end
      end
    end

    test "a command shows its call and output; a long call is shown whole under the header" do
      html =
        show(steps([call("t1", "bash", %{"command" => "mix test"}, result("bash", "green"))]))

      assert text(html, "[data-tool=bash] [data-tool-name]") == "bash"
      assert text(html, "[data-tool=bash] [data-tool-call]") == "mix test"
      assert text(html, "[data-tool=bash] pre[data-tool-output]") == "green"

      html =
        show(steps([call("t1", "bash", %{"command" => "cd a\nmix test"}, result("bash", "ok"))]))

      assert text(html, "[data-tool=bash] [data-tool-call]") == "cd a"
      assert text(html, "[data-tool=bash] > pre:not([data-tool-output])") == "cd a mix test"

      read = call("t1", "read", %{"path" => "a.ex", "limit" => 5}, result("read", "defmodule A"))
      assert text(show(steps([read])), "[data-tool=read] [data-tool-call]") == "a.ex:1-5"
    end

    test "an edit shows its diff instead of its result, and a write the file it wrote" do
      edited =
        put_in(result("edit", "Replaced 1 block"), ["model", Access.at(0), "details"], %{
          "diff" => "-1 old\n+1 new"
        })

      html = show(steps([call("t1", "edit", %{"path" => "a.ex"}, edited)]))
      assert text(html, "[data-tool=edit] [data-diff]") =~ "+1 new"
      refute found?(html, "[data-tool-output]")
      refute text(html, "[data-tool=edit]") =~ "Replaced 1 block"

      write =
        call(
          "t1",
          "write",
          %{"path" => "a.ex", "content" => "defmodule A"},
          result("write", "ok")
        )

      html = show(steps([write]))
      assert text(html, "[data-tool=write] > pre:not([data-tool-output])") == "defmodule A"
    end

    test "a closed group of steps summarises what was done and what failed" do
      read = fn id, path -> call(id, "read", %{"path" => path}, result("read", "defmodule")) end
      failed = result("bash", "", error: "Command exited with code 1")

      html =
        show(
          steps([
            %{type: :thinking, text: "Hm."},
            read.("t1", "a.ex"),
            read.("t2", "a.ex"),
            read.("t3", "b.ex"),
            call("t4", "bash", %{"command" => "mix test"}, failed)
          ])
        )

      assert text(html, "details:not([open]) > summary [data-row-text]") ==
               "Thought, read 2 files, ran 1 command"

      assert text(html, "[data-row-note]") == "· 1 failed"
      assert found?(html, "[data-steps] > [data-tool=bash]")
    end
  end

  describe "timings" do
    test "a tool's recorded duration is shown, from zero up" do
      for {ms, expected} <- [{0, "0ms"}, {125, "125ms"}, {1250, "1.3s"}, {61_000, "1m 1s"}] do
        html = show(steps([call("t1", "bash", %{}, timed(result("bash", "ok"), ms))]))
        assert text(html, "#tool-t1-duration[data-tool-duration]") == expected
      end
    end

    test "tool-only responses keep their own header and the results of their own calls" do
      assistant = fn id, tool ->
        %{
          id: id,
          kind: "pi.assistant",
          payload: %{
            "model" => [
              %{
                "model" => "gpt-6.1-sol",
                "durationMs" => 1500,
                "stopReason" => "toolUse",
                "content" => [
                  %{"type" => "toolCall", "id" => tool, "name" => "bash", "arguments" => %{}}
                ]
              }
            ]
          }
        }
      end

      payload = timed(result("bash", "previous output"), 250)

      {[first, second], _} =
        transcript([
          assistant.("first", "t1"),
          %{id: "result", kind: "pi.tool-result", payload: payload},
          assistant.("second", "t2")
        ])

      assert text(show(first), "[data-response-content] #tool-t1-duration") == "250ms"
      assert text(show(first), "[data-model-response] > header") == "gpt-6.1-sol · 1.5s"
      assert found?(show(second), "[data-response-content] [data-tool=bash]")
      refute text(show(second), "[data-response-content]") =~ "previous output"
    end

    test "a response with several text blocks is one response with one timing" do
      item = %{
        id: "assistant",
        kind: "pi.assistant",
        payload: %{
          "model" => [
            %{
              "model" => "gpt-5.4",
              "durationMs" => 2500,
              "stopReason" => "stop",
              "content" => [
                %{"type" => "text", "text" => "Hello"},
                %{"type" => "text", "text" => "Done"}
              ]
            }
          ]
        }
      }

      assert [%{kind: "response", parts: [_, _]} = response] = parts(item)
      html = show(response)
      assert text(html, "[data-response-content]") =~ ~r/Hello.*Done/
      assert Enum.count(find(html, "[data-model-duration]")) == 1
      assert text(html, "#assistant-timing[data-model-duration]") == "gpt-5.4 · 2.5s"
    end

    test "run_duration/2 is none before the run starts, then counts to now or its end" do
      start = ~U[2026-10-08 12:00:00Z]
      run = &%{status: &1, inserted_at: start, updated_at: &2}
      later = ~U[2026-10-09 12:00:00Z]

      assert run_duration(run.(:picked_up, start), later) == "—"
      assert run_duration(run.(:completed, ~U[2026-10-08 12:26:59Z]), later) == "26m"
      assert run_duration(run.(:failed, ~U[2026-10-08 13:05:00Z]), later) == "1h 5m"

      for status <- ~w(provisioning running waiting_for_input handing_off)a do
        under_way = run.(status, ~U[2026-10-08 12:01:00Z])
        assert run_duration(under_way, ~U[2026-10-08 12:00:59Z]) == "<1m"
        assert run_duration(under_way, ~U[2026-10-08 14:02:00Z]) == "2h 2m"
      end
    end

    test "local_time/1 shows the time for today and the date too for another day" do
      assert local_time(DateTime.utc_now()) =~ ~r/^\d\d:\d\d$/
      assert local_time(~U[2020-03-07 12:00:00Z]) =~ ~r/^\d{1,2} Mar \d\d:\d\d$/
      assert local_time(nil) == ""
    end
  end

  test "exit_code/1 reads the code pi names, never what the command printed" do
    failed = result("bash", "1 test, 1 failure", error: "Command exited with code 2")
    printed = result("bash", "Command exited with code 3")

    for {payload, code} <- [
          {result("bash", "6 tests, 0 failures"), 0},
          {failed, 2},
          # Without the structured list, the block at the end of the content says it.
          {Map.delete(failed, "data"), 2},
          {result("bash", "", error: ["Full output: /tmp/out", "Command exited with code 127"]),
           127},
          {printed, 0},
          {Map.delete(printed, "data"), 0},
          {result("bash", "", error: "Command timed out after 30 seconds"), nil},
          {result("read", "", error: "Command exited with code 2"), nil},
          {result("read", "defmodule A"), nil},
          {nil, nil}
        ] do
      assert exit_code(payload) == code
    end
  end

  test "notes, compactions, errors and unknown kinds are lines between the messages" do
    note = %{
      id: "n",
      kind: "conductor.note",
      payload: %{"title" => "Setup", "text" => "mix deps.get"}
    }

    html = show(note)
    assert text(html, "details[data-note]:not([open]) > summary [data-rule]") == "Setup"

    assert text(html, "details[data-note] > pre[tabindex='0'][aria-label='Setup']") ==
             "mix deps.get"

    html = show(put_in(note.payload["text"], ""))
    assert text(html, "[data-rule]") == "Setup"
    refute found?(html, "details")

    assert text(show(%{id: "c", kind: "pi.compaction", payload: %{}}), "[data-rule]") ==
             "context compacted"

    assert text(show(%{id: "e", kind: "error", text: "Operation aborted"}), "[data-error]") ==
             "Operation aborted"

    assert text(show(%{id: "x", kind: "pi.other", payload: %{}}), "div") == "pi.other"
  end

  # What `selector` matches in a rendered component, and the text of the first match with its white space put right.
  defp find(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp found?(html, selector), do: Enum.count(find(html, selector)) > 0

  defp text(html, selector) do
    case Enum.at(find(html, selector), 0) do
      nil -> nil
      node -> node |> LazyHTML.text() |> String.split() |> Enum.join(" ")
    end
  end

  defp show(item), do: render_component(&transcript_item/1, item: item)

  defp call(id, name, args, result \\ nil),
    do: %{type: :tool, id: id, name: name, args: args, result: result}

  defp steps(steps, active \\ false),
    do: %{id: "s", kind: "steps", steps: steps, active: active}

  defp timed(payload, ms),
    do: Map.update!(payload, "model", fn [message] -> [Map.put(message, "durationMs", ms)] end)

  # A tool result as pi stores it: the output, then the diagnostics as the model sees them.
  defp result(name, output, opts \\ []) do
    diagnostics =
      for message <- List.wrap(opts[:error]), do: %{"severity" => "error", "message" => message}

    lines = Enum.map_join(diagnostics, "\n", &"[error] #{&1["message"]}")

    harness =
      if diagnostics == [],
        do: [],
        else: [%{"type" => "text", "text" => "<harness>\n#{lines}\n</harness>"}]

    message = %{
      "role" => "toolResult",
      "toolCallId" => "t1",
      "toolName" => name,
      "content" => [%{"type" => "text", "text" => output}] ++ harness,
      "isError" => diagnostics != []
    }

    %{
      "id" => 2,
      "kind" => "pi.tool-result",
      "model" => [message],
      "data" => %{"diagnostics" => diagnostics}
    }
  end
end
