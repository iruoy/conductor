defmodule Conductor.ClassificationTest do
  use Conductor.DataCase, async: false
  import Conductor.Fixtures
  alias Conductor.{Classification, Runs}

  test "persists suggestions once without changing Size routing or models" do
    project = project_fixture()

    issue =
      snapshot("shop-1", "Root", %{"subtasks" => [snapshot("shop-2", "Child", %{"size" => "S"})]})

    {:ok, run} = Runs.create_run(project, "shop-1", issue)

    suggestion = %{
      "status" => "suggested",
      "complexity" => "low",
      "reason" => "Small edit",
      "provider" => "test",
      "model" => "classifier",
      "latency_ms" => 10,
      "usage" => %{"input" => 20}
    }

    assert {:ok, _} =
             Classification.persist(run, fn command, timeout ->
               assert command == %{type: "classify_issue", run_id: run.id, issue: issue}
               assert timeout == 7_000
               {:ok, %{"#1" => suggestion}}
             end)

    saved = Runs.get_run!(run.id)
    assert saved.classifications["#1"] == suggestion
    assert saved.classifications["#2"]["status"] == "explicit"
    assert saved.classifications["#2"]["complexity"] == "low"
    assert saved.models == run.models
    assert saved.issue_snapshot == issue
    assert saved.status == run.status
    assert :ok = Classification.persist(saved, fn _, _ -> flunk("must not reclassify") end)
  end

  test "errors, timeouts, exceptions and malformed results persist safe fallback" do
    project = project_fixture()

    callbacks = [
      fn _, _ -> {:error, :offline} end,
      fn _, _ -> exit(:timeout) end,
      fn _, _ -> raise "broken" end,
      fn _, _ -> {:ok, %{"#1" => %{"complexity" => "low"}}} end
    ]

    for {call, index} <- Enum.with_index(callbacks) do
      {:ok, run} = Runs.create_run(project, "shop-#{index}", snapshot("shop-1"))
      assert {:ok, _} = Classification.persist(run, call)
      saved = Runs.get_run!(run.id)
      assert saved.classifications["#1"]["status"] == "fallback"
      assert saved.classifications["#1"]["complexity"] == "high"
      assert saved.status == :picked_up
    end
  end
end
