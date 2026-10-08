defmodule ConductorWeb.RunComponentsTest do
  use ExUnit.Case, async: true
  import ConductorWeb.RunComponents
  import Phoenix.LiveViewTest, only: [render_component: 2]

  test "tool scroll boxes are named keyboard stops without region landmarks" do
    for attrs <- [
          [name: "bash", args: %{"command" => "echo one\necho two"}, output: "one\ntwo"],
          [name: "write", args: %{"path" => "file", "content" => "contents"}],
          [name: "edit", args: %{"path" => "file"}, diff: "-1 old\n+1 new"],
          [name: "bash", args: %{}, output: "failed", error: true]
        ] do
      html = render_component(&tool/1, attrs)
      blocks = find(html, "pre")
      assert Enum.count(blocks) > 0

      assert Enum.count(blocks) ==
               Enum.count(
                 find(html, "pre.scrollable-output[tabindex='0'][role='group'][aria-label]")
               )

      refute found?(html, "[role='region']")
    end
  end

  describe "run_duration/2" do
    @start ~U[2026-10-08 12:00:00Z]

    defp run(status, updated_at),
      do: %{status: status, inserted_at: @start, updated_at: updated_at}

    test "a run that has not started has none" do
      assert run_duration(run(:picked_up, @start), ~U[2026-10-08 13:00:00Z]) == "—"
    end

    test "a finished run took until its last update" do
      assert run_duration(run(:completed, ~U[2026-10-08 12:26:59Z]), ~U[2026-10-09 12:00:00Z]) ==
               "26m"

      assert run_duration(run(:failed, ~U[2026-10-08 13:05:00Z]), ~U[2026-10-09 12:00:00Z]) ==
               "1h 5m"
    end

    test "a run under way counts up to now, to the minute" do
      for status <- ~w(provisioning running waiting_for_input handing_off)a do
        run = run(status, ~U[2026-10-08 12:01:00Z])
        assert run_duration(run, ~U[2026-10-08 12:00:59Z]) == "<1m"
        assert run_duration(run, ~U[2026-10-08 12:21:30Z]) == "21m"
        assert run_duration(run, ~U[2026-10-08 14:02:00Z]) == "2h 2m"
      end
    end
  end

  describe "local_time/1" do
    test "shows the time for today and the date too for another day" do
      assert local_time(DateTime.utc_now()) =~ ~r/^\d\d:\d\d$/
      assert local_time(~U[2020-03-07 12:00:00Z]) =~ ~r/^\d{1,2} Mar \d\d:\d\d$/
      assert local_time(nil) == ""
    end
  end

  test "status_label/1 puts a status in words" do
    assert status_label(:waiting_for_input) == "waiting for input"
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

  defp user(text),
    do: %{
      id: "u",
      kind: "pi.user",
      payload: %{"model" => [%{"role" => "user", "content" => text}]}
    }

  defp call(id, name, args, result \\ nil),
    do: %{type: :tool, id: id, name: name, args: args, result: result}

  defp steps(steps, active \\ false),
    do: %{id: "s", kind: "steps", steps: steps, active: active}

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

  test "context actions retain assistant and tool-result entries when steps are folded" do
    assistant =
      item(7, %{
        "id" => 1,
        "kind" => "pi.assistant",
        "model" => [
          %{
            "role" => "assistant",
            "content" => [
              %{
                "type" => "toolCall",
                "id" => "t1",
                "name" => "bash",
                "arguments" => %{"command" => "ls"}
              }
            ]
          }
        ]
      })

    result_item = item(7, result("bash", "files"))

    next =
      item(7, %{
        "id" => 3,
        "kind" => "pi.assistant",
        "model" => [
          %{
            "role" => "assistant",
            "content" => [%{"type" => "thinking", "thinking" => "next step"}]
          }
        ]
      })

    {[group], _} = transcript([assistant, result_item, next])
    html = show(group)

    for id <- [1, 2, 3] do
      assert found?(
               html,
               "button[phx-click=inspect_context][phx-value-conversation='7'][phx-value-entry='#{id}']"
             )
    end

    # Synthetic/live-only rows have no persisted entry to inspect.
    refute found?(
             show(%{id: "live", kind: "text", text: "Streaming"}),
             "button[phx-click=inspect_context]"
           )
  end

  test "reset and compaction entries can be inspected" do
    for kind <- ["pi.reset", "pi.compaction"] do
      html = show(item(8, %{"id" => 4, "kind" => kind}))
      assert found?(html, "#inspect-ev-8-e-4-4[phx-value-conversation='8'][phx-value-entry='4']")
    end
  end

  describe "recorded execution timings" do
    test "tool timing includes zero and subsecond executions; old and invalid results omit it" do
      for {ms, expected} <- [{0, "0ms"}, {125, "125ms"}, {1250, "1.3s"}, {61_000, "1m 1s"}] do
        payload = result("bash", "ok")

        payload =
          Map.update!(payload, "model", fn [message] -> [Map.put(message, "durationMs", ms)] end)

        html = show(steps([call("t1", "bash", %{}, payload)]))
        assert text(html, "#tool-t1-duration[data-tool-duration]") == expected
      end

      for ms <- [nil, -1, "bad"] do
        payload = result("bash", "ok")

        payload =
          Map.update!(payload, "model", fn [message] -> [Map.put(message, "durationMs", ms)] end)

        refute found?(show(steps([call("t1", "bash", %{}, payload)])), "[data-tool-duration]")
      end
    end

    test "tool-only responses keep their own header and tool execution times" do
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

      payload = result("bash", "previous output")

      payload =
        Map.update!(payload, "model", fn [message] ->
          [Map.merge(message, %{"toolCallId" => "t1", "durationMs" => 250})]
        end)

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

    test "model response timing is shown once without duplicating multi-block responses" do
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

      shown = parts(item)
      assert [%{kind: "response", parts: [_, _]} = response] = shown
      assert found?(show(response), "[data-model-response] > header[data-model-duration]")
      assert text(show(response), "[data-response-content]") =~ "Hello"
      assert text(show(response), "[data-response-content]") =~ "Done"
      assert text(show(hd(shown)), "#assistant-timing[data-model-duration]") == "gpt-5.4 · 2.5s"
      assert List.last(shown).final

      old = put_in(item.payload["model"], [%{"content" => [], "stopReason" => "stop"}])
      refute Enum.any?(parts(old), &(&1.kind == "response"))
    end
  end

  describe "exit_code/1" do
    test "a command that went well exited with 0" do
      assert exit_code(result("bash", "6 tests, 0 failures")) == 0
    end

    test "a command pi failed exited with the code pi names" do
      failed = result("bash", "1 test, 1 failure", error: "Command exited with code 2")
      assert exit_code(failed) == 2
      # Without the structured list, the block at the end of the content says it.
      assert exit_code(Map.delete(failed, "data")) == 2

      assert exit_code(
               result("bash", "",
                 error: ["Full output: /tmp/out", "Command exited with code 127"]
               )
             ) == 127
    end

    test "what the command printed itself does not count" do
      printed = result("bash", "Command exited with code 3")
      assert exit_code(printed) == 0
      assert exit_code(Map.delete(printed, "data")) == 0
    end

    test "a command that ended some other way, another tool and no result have none" do
      assert exit_code(result("bash", "", error: "Command timed out after 30 seconds")) == nil
      assert exit_code(result("read", "", error: "Command exited with code 2")) == nil
      assert exit_code(result("read", "defmodule A")) == nil
      assert exit_code(nil) == nil
    end
  end

  describe "transcript_item/1 messages" do
    test "the first prompt of a transcript is the issue, a later one is you" do
      {[first, second], _turn} = transcript([user("Fix **it**"), %{user("Use tabs") | id: "u2"}])

      html = show(first)
      assert text(html, "[data-from=input] [data-badge]") == "IS"
      assert text(html, "[data-from=input] [data-label]") == "Issue"
      assert text(html, "[data-from=input] .prose strong") == "it"

      html = show(second)
      assert text(html, "[data-from=input] [data-badge]") == "YOU"
      assert text(html, "[data-from=input] [data-label]") == "You"
    end

    test "what the agent says is the agent's, as Markdown" do
      html = show(%{id: "t", kind: "text", text: "It is **done**.", final: true, at: nil})
      assert text(html, "[data-from=agent] [data-badge]") == "AG"
      assert text(html, "[data-from=agent] [data-label]") == "Agent"
      assert text(html, "[data-from=agent] .prose strong") == "done"
    end
  end

  describe "transcript_item/1 steps" do
    defp read, do: call("t1", "read", %{"path" => "a.ex"}, result("read", "defmodule A"))
    defp bash, do: call("t2", "bash", %{"command" => "mix test"}, result("bash", "all green"))

    test "a group is one closed line that says what was done" do
      thought = %{type: :thinking, text: "Hm."}
      again = %{read() | id: "t3"}
      other = call("t4", "read", %{"path" => "b.ex"}, result("read", "defmodule B"))

      html = show(steps([thought, read(), again, other, bash()]))
      assert found?(html, "details:not([open]) > summary")

      assert text(html, "details > summary [data-row-text]") ==
               "Thought, read 2 files, ran 1 command"

      refute found?(html, "details > summary [data-pulse]")
      refute found?(html, "[data-row-note]")
      assert found?(html, "[data-steps] > details")
      assert found?(html, "[data-steps] > [data-tool=bash]")
    end

    test "a group the agent is at work in says what goes on, after a pulsing dot" do
      html = show(steps([read(), call("t2", "bash", %{"command" => "mix test"})], true))
      assert text(html, "details > summary [data-row-text]") == "Running commands"
      assert found?(html, "details > summary > [data-pulse].motion-safe\\:animate-dot-pulse")
      assert text(html, "[data-steps] [data-tool=bash] [data-tool-status=running]") == "running"
    end

    test "a group counts what failed in it" do
      failed =
        call(
          "t2",
          "bash",
          %{"command" => "mix test"},
          result("bash", "", error: "Command exited with code 1")
        )

      assert text(show(steps([read(), failed])), "[data-row-note]") == "· 1 failed"
    end

    test "the work of a turn is one line with how long it took at the end" do
      text = %{id: "t", kind: "text", text: "Looking around.", final: false, at: nil}
      work = %{id: "w", kind: "work", parts: [text, steps([read(), bash()])], ms: 125_000}

      html = show(work)

      assert text(html, "details:not([open]) > summary [data-row-text]") ==
               "Read 1 file, ran 1 command"

      assert text(html, "details > summary [data-row-meta]") == "2m 5s"
      assert found?(html, "[data-work] [data-from=agent]")
      assert found?(html, "[data-work] [data-steps] [data-tool=read]")

      refute found?(show(%{work | ms: nil}), "[data-row-meta]")
    end
  end

  describe "transcript_item/1 thinking" do
    test "a thought is a line that opens" do
      html = show(steps([%{type: :thinking, text: "Why **not**?"}]))
      assert text(html, "details:not([open]) > summary [data-row-text]") == "Thought"
      assert text(html, "details .prose strong") == "not"
    end

    test "thinking that streams in shows as it comes, after a dot that pulses unless motion is reduced" do
      html =
        render_component(&reasoning/1,
          id: "live-thinking",
          text: "Both tests *pass*.",
          streaming: true
        )

      assert text(html, "#live-thinking[data-thinking] > div > span") == "Thinking"
      assert text(html, "#live-thinking .prose em") == "pass"
      assert found?(html, "#live-thinking > [data-pulse].motion-safe\\:animate-dot-pulse")

      html = render_component(&reasoning/1, id: "live-thinking", text: "Both tests pass.")
      assert text(html, "details#live-thinking > summary [data-row-text]") == "Thought"
    end
  end

  describe "transcript_item/1 tools" do
    test "a command that went well shows its exit code and what it put out" do
      html =
        show(
          steps([
            call("t1", "bash", %{"command" => "mix test"}, result("bash", "6 tests, 0 failures"))
          ])
        )

      assert text(html, "[data-tool=bash] [data-tool-name]") == "bash"
      assert text(html, "[data-tool=bash] [data-tool-call]") == "mix test"
      assert text(html, "[data-tool=bash] [data-tool-status=ok]") == "exit 0"
      assert text(html, "[data-tool=bash] pre[data-tool-output]") == "6 tests, 0 failures"
      refute found?(html, "[data-tool].border-chip-error-line")
      refute found?(html, "[data-tool] [data-pulse].motion-safe\\:animate-dot-pulse")
    end

    test "a command that failed shows its exit code, in a box with an error border" do
      failed = result("bash", "1 test, 1 failure", error: "Command exited with code 2")
      html = show(steps([call("t1", "bash", %{"command" => "mix test"}, failed)]))

      assert text(html, "[data-tool=bash].border-chip-error-line [data-tool-status=error]") ==
               "exit 2"

      assert text(html, "[data-tool=bash] pre[data-tool-output]") =~ "1 test, 1 failure"
    end

    test "a command that ended without an exit code, and another tool, are failed or done" do
      timeout = result("bash", "", error: "Command timed out after 30 seconds")
      html = show(steps([call("t1", "bash", %{"command" => "sleep 99"}, timeout)]))

      assert text(html, "[data-tool=bash].border-chip-error-line [data-tool-status=error]") ==
               "failed"

      html =
        show(
          steps([
            call("t1", "read", %{"path" => "a.ex", "limit" => 5}, result("read", "defmodule A"))
          ])
        )

      assert text(html, "[data-tool=read] [data-tool-call]") == "a.ex:1-5"
      assert text(html, "[data-tool=read] [data-tool-status=ok]") == "done"

      html =
        show(
          steps([call("t1", "read", %{"path" => "no.ex"}, result("read", "", error: "ENOENT"))])
        )

      assert text(html, "[data-tool=read].border-chip-error-line [data-tool-status=error]") ==
               "failed"
    end

    test "a call without a result says nothing unless the agent is at work on it" do
      open = call("t1", "bash", %{"command" => "mix test"})
      refute found?(show(steps([open])), "[data-tool-status]")

      html = show(steps([open], true))
      assert text(html, "[data-tool=bash] [data-tool-status=running]") == "running"

      assert found?(
               html,
               "[data-tool-status=running] > [data-pulse].motion-safe\\:animate-dot-pulse"
             )
    end

    test "a tool that runs live shows what it has put out so far" do
      html =
        render_component(&tool/1,
          id: "live-tool-t1",
          name: "bash",
          args: %{"command" => "mix test"},
          output: "....\e[32m..\e[0m",
          streaming: true
        )

      assert text(html, "#live-tool-t1[data-tool=bash] [data-tool-status=running]") == "running"
      assert text(html, "#live-tool-t1 pre[data-tool-output]") == "......"
    end

    test "a call that takes more than a line is shown whole under the header" do
      html =
        show(steps([call("t1", "bash", %{"command" => "cd a\nmix test"}, result("bash", "ok"))]))

      assert text(html, "[data-tool=bash] [data-tool-call]") == "cd a"
      assert text(html, "[data-tool=bash] > pre:not([data-tool-output])") == "cd a mix test"
    end

    test "an edit shows its diff and a write the file it wrote" do
      edited =
        put_in(result("edit", "ok"), ["model", Access.at(0), "details"], %{
          "diff" => "-1 old\n+1 new"
        })

      html = show(steps([call("t1", "edit", %{"path" => "a.ex"}, edited)]))
      assert text(html, "[data-tool=edit] [data-diff] .text-success") =~ "new"
      assert text(html, "[data-tool=edit] [data-diff] .text-error") =~ "old"
      refute found?(html, "[data-tool-output]")

      html =
        show(
          steps([
            call(
              "t1",
              "write",
              %{"path" => "a.ex", "content" => "defmodule A"},
              result("write", "ok")
            )
          ])
        )

      assert text(html, "[data-tool=write] > pre:not([data-tool-output])") == "defmodule A"
    end

    test "a result without its call stands on its own" do
      failed = result("bash", "boom", error: "Command exited with code 1")
      html = show(%{id: "r", kind: "pi.tool-result", payload: failed})
      assert text(html, "[data-tool='bash result'] [data-tool-status=error]") == "exit 1"
    end
  end

  describe "transcript_item/1 lines between the messages" do
    test "a note is a centred line that opens to what it has to show" do
      note = %{
        id: "n",
        kind: "conductor.note",
        payload: %{"title" => "Setup", "text" => "mix deps.get"}
      }

      html = show(note)
      assert text(html, "details[data-note]:not([open]) > summary [data-rule]") == "Setup"
      assert text(html, "details[data-note] > pre") == "mix deps.get"

      assert found?(
               html,
               "details[data-note] > pre.scrollable-output[tabindex='0'][role='group'][aria-label='Setup']"
             )

      html = show(put_in(note.payload["text"], ""))
      assert text(html, "[data-rule]") == "Setup"
      refute found?(html, "details")
    end

    test "a compaction is a centred line" do
      assert text(show(%{id: "c", kind: "pi.compaction", payload: %{}}), "[data-rule]") ==
               "context compacted"
    end

    test "an error and a kind that is not known are plain lines" do
      assert text(show(%{id: "e", kind: "error", text: "Operation aborted"}), "[data-error]") ==
               "Operation aborted"

      assert show(%{id: "x", kind: "pi.other", payload: %{}}) |> text("div") == "pi.other"
    end
  end
end
