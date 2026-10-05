defmodule Conductor.Runs.NotifierTest do
  use Conductor.DataCase, async: false
  import Conductor.Fixtures

  alias Conductor.Runs
  alias Conductor.Runs.{Question, Run}

  test "direct Ash writes broadcast to both run topics with the project loaded" do
    project = project_fixture()
    project_id = project.id
    id = "SHOP-30-1"
    Runs.subscribe()
    Runs.subscribe(id)

    run =
      Ash.create!(Run, %{
        id: id,
        issue_key: "SHOP-30",
        attempt: 1,
        project_id: project.id
      })

    assert_run_notification(id, project_id, :picked_up)

    for {action, attrs} <- [
          {:set_workspace_path, %{workspace_path: "/tmp/workspace"}},
          {:set_branch, %{branch: "feature/test"}},
          {:clear_workspace, %{}},
          {:pump, %{}},
          {:provision_end, %{}},
          {:wait_for_input, %{}},
          {:resume, %{}},
          {:settle, %{}},
          {:complete, %{pr_url: "https://example.com/pr/1"}}
        ],
        reduce: run do
      run ->
        updated = run |> Ash.Changeset.for_update(action, attrs) |> Ash.update!()
        assert_run_notification(id, project_id, updated.status)
        updated
    end

    refute_received {:run_updated, _}
  end

  test "failure actions also broadcast to both topics" do
    project = project_fixture()
    Runs.subscribe()

    for {action, issue_key} <- [
          {:abort, "SHOP-34"},
          {:fail, "SHOP-35"},
          {:hand_off_failed, "SHOP-36"}
        ] do
      {:ok, run} = Runs.create_run(project, issue_key, %{})
      assert_receive {:run_updated, %{id: id}}
      assert id == run.id
      Runs.subscribe(run.id)

      run =
        if action == :hand_off_failed do
          run = run |> Ash.Changeset.for_update(:pump, %{}) |> Ash.update!()
          assert_run_notification(run.id, project.id, :provisioning)
          run = run |> Ash.Changeset.for_update(:settle, %{}) |> Ash.update!()
          assert_run_notification(run.id, project.id, :handing_off)
          run
        else
          run
        end

      run |> Ash.Changeset.for_update(action, %{}) |> Ash.update!()
      assert_run_notification(run.id, project.id, :failed)
      Runs.unsubscribe(run.id)
    end

    refute_received {:run_updated, _}
  end

  test "direct question writes notify once and failed writes do not notify" do
    run = run_fixture(project_fixture(), "SHOP-31")
    Runs.subscribe(run.id)
    question = Ash.create!(Question, %{run_id: run.id, qid: "q", text: "Question?"})
    id = question.id
    assert_receive {:question, %{id: ^id, answer: nil}}
    Ash.update!(question, %{answer: "yes"})
    assert_receive {:question, %{id: ^id, answer: "yes"}}
    assert {:error, _} = Runs.complete(run)
    assert {:error, _} = Ash.create(Question, %{run_id: run.id, qid: "invalid"})
    refute_received {:question, _}
    refute_received {:run_updated, _}
  end

  test "transaction notifications wait for commit and are discarded on rollback" do
    run = run_fixture(project_fixture(), "SHOP-32")
    Runs.subscribe(run.id)

    assert {:ok, _} =
             Ash.transaction([Run, Question], fn ->
               {:ok, updated} = Runs.pump(run)
               {:ok, _} = Runs.upsert_question(run.id, "committed", "Question?")
               refute_received {:run_updated, _}
               refute_received {:question, _}
               updated
             end)

    assert_receive {:run_updated, %{status: :provisioning}}
    assert_receive {:question, %{qid: "committed"}}

    assert {:error, _} =
             Ash.transaction([Run, Question], fn ->
               {:ok, _} = Runs.provision_end(Runs.get_run!(run.id))
               {:ok, _} = Runs.upsert_question(run.id, "rolled-back", "Question?")
               refute_received {:run_updated, _}
               refute_received {:question, _}
               Repo.rollback(:cancelled)
             end)

    assert Runs.get_run!(run.id).status == :provisioning
    assert Runs.get_question(run.id, "rolled-back") == nil
    refute_received {:run_updated, _}
    refute_received {:question, _}
  end

  test "transactional run creates and question updates only notify on commit" do
    project = project_fixture()
    Runs.subscribe()
    Runs.subscribe("SHOP-37-1")

    assert {:error, _} =
             Ash.transaction([Run, Question], fn ->
               {:ok, run} = Runs.create_run(project, "SHOP-37", %{})
               {:ok, question} = Runs.upsert_question(run.id, "q", "Question?")
               {:ok, _} = Runs.answer_question(question, "rolled back")
               refute_received {:run_updated, _}
               refute_received {:question, _}
               Repo.rollback(:cancelled)
             end)

    assert Runs.get_run("SHOP-37-1") == nil
    refute_received {:run_updated, _}
    refute_received {:question, _}

    assert {:ok, _} =
             Ash.transaction([Run, Question], fn ->
               {:ok, run} = Runs.create_run(project, "SHOP-37", %{})
               {:ok, question} = Runs.upsert_question(run.id, "q", "Question?")
               {:ok, _} = Runs.answer_question(question, "committed")
               refute_received {:run_updated, _}
               refute_received {:question, _}
             end)

    assert_run_notification("SHOP-37-1", project.id, :picked_up)
    assert_receive {:question, %{qid: "q", answer: nil}}
    assert_receive {:question, %{qid: "q", answer: "committed"}}
    assert Runs.get_question("SHOP-37-1", "q").answer == "committed"
    refute_received {:run_updated, _}
    refute_received {:question, _}
  end

  test "agent event deltas still use the manual streaming broadcast" do
    run = run_fixture(project_fixture(), "SHOP-33")
    Runs.subscribe(run.id)
    event = %{"type" => "message_delta", "text" => "hello"}

    Runs.ingest(%{
      "type" => "agent_event",
      "run_id" => run.id,
      "conversation" => 1,
      "role" => "head",
      "event" => event
    })

    assert_receive {:agent_event, %{conversation: 1, role: "head", event: ^event}}
    assert Runs.list_events(run.id) == []
    refute_received {:run_updated, _}
  end

  defp assert_run_notification(id, project_id, status) do
    for _ <- 1..2 do
      assert_receive {:run_updated, %{id: ^id, status: ^status, project: %{id: ^project_id}}}
    end
  end
end
