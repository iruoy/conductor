# A stand-in for runner/dist/main.js that speaks the same JSON-lines protocol, for ExUnit.
#
# The prompt steers a run: `[fake:hang]` keeps it running, `[fake:ask]` asks a question first, `[fake:fail]` fails it,
# anything else completes it right away. Test-only commands: `fake_settle {run_id, outcome}` settles a run, `crash`
# exits with status 1. With FAKE_RUNNER_STATE set, the state survives restarts in that file, like the real runner.
defmodule FakeRunner do
  def main do
    state = load()

    emit(%{
      type: "ready",
      version: "fake",
      resumed: for({id, %{"status" => "running"}} <- state, do: id)
    })

    loop(state)
  end

  defp loop(state) do
    case IO.read(:stdio, :line) do
      :eof ->
        System.halt(0)

      line ->
        command = JSON.decode!(line)
        {_reply, state} = handle(command, state)
        save(state)
        loop(state)
    end
  end

  defp handle(%{"type" => "hello"} = c, state), do: ok(c, %{version: "fake", resumed: []}, state)

  defp handle(%{"type" => "models"} = c, state) do
    ok(
      c,
      [
        %{
          provider: "faux",
          id: "faux-1",
          name: "Faux 1",
          reasoning: true,
          levels: ["low", "high"]
        }
      ],
      state
    )
  end

  defp handle(%{"type" => "model_default"} = c, state), do: ok(c, "high", state)

  defp handle(%{"type" => "start_run", "run_id" => id, "prompt" => prompt} = c, state) do
    case state[id] do
      nil ->
        run = %{
          "status" => "running",
          "questions" => [],
          "starts" => 1,
          "settled" => nil,
          "cwd" => c["cwd"]
        }

        state = Map.put(state, id, run)
        reply(c, %{conversation_id: 1, status: "running"})
        emit(%{type: "run_state", run_id: id, status: "running"})
        agent(id, %{type: "snapshot", entries: []})

        agent(id, %{
          type: "message_end",
          entry: %{id: 1, kind: "pi.user", model: [%{role: "user", content: prompt}]}
        })

        {:ok, script(id, prompt, state)}

      run ->
        state = put_in(state[id]["starts"], run["starts"] + 1)
        ok(c, %{conversation_id: 1, status: run["status"]}, state)
    end
  end

  defp handle(%{"type" => "answer", "run_id" => id, "qid" => qid} = c, state) do
    case state[id] do
      %{"status" => "waiting_for_input"} = run ->
        questions =
          Enum.map(
            run["questions"],
            &if(&1["qid"] == qid, do: %{&1 | "answered" => true}, else: &1)
          )

        state = Map.put(state, id, %{run | "status" => "running", "questions" => questions})
        reply(c, %{submission_id: 2})
        emit(%{type: "run_state", run_id: id, status: "running"})
        {:ok, settle(state, id, "completed")}

      _ ->
        error(c, "run #{id} is not waiting", state)
    end
  end

  defp handle(%{"type" => "abort", "run_id" => id} = c, state) do
    if state[id] do
      reply(c, %{status: "aborting"})
      {:ok, settle(state, id, "failed", "aborted")}
    else
      error(c, "unknown run #{id}", state)
    end
  end

  defp handle(%{"type" => "sync"} = c, state) do
    runs = for {id, run} <- state, do: Map.put(run, "run_id", id)
    ok(c, %{runs: runs}, state)
  end

  defp handle(%{"type" => "fake_settle", "run_id" => id, "outcome" => outcome} = c, state) do
    reply(c, %{})
    {:ok, settle(state, id, outcome)}
  end

  defp handle(%{"type" => "crash"}, _state), do: System.halt(1)
  defp handle(c, state), do: error(c, "unknown command #{c["type"]}", state)

  defp script(id, prompt, state) do
    cond do
      prompt =~ "[fake:hang]" ->
        state

      prompt =~ "[fake:ask]" ->
        question = %{"qid" => "q1", "text" => "Which way?", "answered" => false}
        emit(%{type: "question", run_id: id, qid: "q1", text: "Which way?"})
        emit(%{type: "run_state", run_id: id, status: "waiting_for_input"})
        update_in(state[id], &%{&1 | "status" => "waiting_for_input", "questions" => [question]})

      prompt =~ "[fake:fail]" ->
        settle(state, id, "failed", "could not do it")

      true ->
        settle(state, id, "completed")
    end
  end

  defp settle(state, id, outcome, error \\ nil) do
    summary = if outcome == "completed", do: "Did it.\nDONE", else: ""
    settled = %{"outcome" => outcome, "summary" => summary, "error" => error}

    entry = %{
      id: 2,
      kind: "pi.assistant",
      model: [%{role: "assistant", content: [%{type: "text", text: summary}]}]
    }

    agent(id, %{type: "message_end", entry: entry})
    emit(Map.merge(%{"type" => "run_settled", "run_id" => id}, settled))
    update_in(state[id], &%{&1 | "status" => "settled", "settled" => settled})
  end

  defp agent(id, event),
    do: emit(%{type: "agent_event", run_id: id, conversation: 1, role: "head", event: event})

  defp ok(c, result, state) do
    reply(c, result)
    {:ok, state}
  end

  defp error(c, message, state) do
    emit(%{type: "reply", id: c["id"], ok: false, error: message})
    {:error, state}
  end

  defp reply(c, result), do: emit(%{type: "reply", id: c["id"], ok: true, result: result})

  defp emit(event) do
    seq = Process.get(:seq, 0) + 1
    Process.put(:seq, seq)
    IO.write([JSON.encode!(Map.put(event, :seq, seq)), ?\n])
  rescue
    # Phoenix closed the port; like the real runner, just go away.
    ErlangError -> System.halt(0)
  end

  defp load do
    with path when is_binary(path) <- System.get_env("FAKE_RUNNER_STATE"),
         {:ok, text} <- File.read(path) do
      JSON.decode!(text)
    else
      _ -> %{}
    end
  end

  defp save(state) do
    if path = System.get_env("FAKE_RUNNER_STATE"), do: File.write!(path, JSON.encode!(state))
  end
end

FakeRunner.main()
