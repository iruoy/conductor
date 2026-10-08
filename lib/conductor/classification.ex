defmodule Conductor.Classification do
  @moduledoc "Shadow-only size audit. Never changes the prompt or routing models."
  alias Conductor.{Prompt, Runner, Runs}

  @timeout 7_000

  def persist(run, call \\ &Runner.call/2)
  def persist(%{classifications: classifications}, _call) when is_map(classifications), do: :ok

  def persist(run, call) do
    started = System.monotonic_time(:millisecond)
    result = classify(call, %{type: "classify_issue", run_id: run.id, issue: run.issue_snapshot})
    elapsed = System.monotonic_time(:millisecond) - started
    snapshot = run.issue_snapshot || %{}

    classifications =
      Map.new([snapshot | snapshot["subtasks"] || []], fn issue ->
        key = issue["key"] || run.issue_key

        entry =
          case result do
            {:ok, entries} when is_map(entries) -> entries[key]
            _ -> nil
          end

        value =
          cond do
            is_binary(issue["size"]) and String.trim(issue["size"]) != "" ->
              %{
                "status" => "explicit",
                "complexity" => Prompt.complexity(issue),
                "reason" => "Explicit Size: #{issue["size"]}",
                "provider" => nil,
                "model" => nil,
                "latency_ms" => 0
              }

            valid?(entry) ->
              entry

            true ->
              %{
                "status" => "fallback",
                "complexity" => "high",
                "reason" =>
                  "Classifier unavailable or invalid response; existing routing retained",
                "provider" => nil,
                "model" => nil,
                "latency_ms" => elapsed
              }
          end

        {key, value}
      end)

    Runs.set_classifications(run, %{classifications: classifications})
  end

  defp classify(call, command) do
    call.(command, @timeout)
  rescue
    _ -> {:error, :classifier_failed}
  catch
    :exit, _ -> {:error, :classifier_unavailable}
  end

  defp valid?(entry) when is_map(entry) do
    entry["status"] in ~w(suggested fallback) and
      entry["complexity"] in ~w(low medium high) and is_binary(entry["reason"]) and
      is_number(entry["latency_ms"]) and entry["latency_ms"] >= 0 and
      (is_nil(entry["provider"]) or is_binary(entry["provider"])) and
      (is_nil(entry["model"]) or is_binary(entry["model"]))
  end

  defp valid?(_), do: false
end
