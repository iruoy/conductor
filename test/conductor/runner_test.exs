defmodule Conductor.RunnerTest do
  use Conductor.DataCase, async: false
  import Conductor.Fixtures
  alias Conductor.{Runner, Runs}

  setup do
    start_supervised!({Runner, forward_to: self()})
    :ok
  end

  test "round-trips commands" do
    assert {:ok, %{"version" => "fake"}} = Runner.call(%{type: "hello"})
    assert {:ok, [%{"provider" => "faux", "id" => "faux-1"}]} = Runner.call(%{type: "models"})
    assert {:error, "unknown command nope"} = Runner.call(%{type: "nope"})
  end

  test "ingests events and forwards lifecycle events" do
    run = run_fixture(project_fixture(), "SHOP-1", %{status: :running})
    assert_receive {:runner, %{"type" => "ready"}}, 5_000

    assert {:ok, %{"status" => "running"}} =
             Runner.call(%{
               type: "start_run",
               run_id: run.id,
               cwd: "/tmp",
               prompt: "Go",
               models: %{}
             })

    assert_receive {:runner,
                    %{"type" => "run_settled", "run_id" => "SHOP-1-1", "outcome" => "completed"}}

    assert [%{kind: "pi.user", entry: "e:1"}, %{kind: "pi.assistant"}] = Runs.list_events(run.id)
    assert [{1, "head"}] = Runs.conversations(run.id)
  end

  test "answers pending callers and stops when the runner exits" do
    pid = Process.whereis(Runner)
    ref = Process.monitor(pid)
    assert {:error, :runner_exited} = Runner.call(%{type: "crash"})
    assert_receive {:DOWN, ^ref, :process, ^pid, {:runner_exited, 1}}
  end
end
