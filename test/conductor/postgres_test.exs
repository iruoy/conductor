defmodule Conductor.PostgresTest do
  use Conductor.DataCase, async: true
  import Conductor.Fixtures
  alias Conductor.{Config, Runs}

  test "repository deletion returns a Ash error when a project references it" do
    project = project_fixture()

    assert {:error, %Ash.Error.Invalid{} = error} = Config.delete_repo(project.repo)
    assert errors_on(error) == %{name: ["is used by a project"]}
  end

  test "project deletion returns a Ash error when a run references it" do
    project = project_fixture()
    run_fixture(project, "SHOP-1")

    assert {:error, %Ash.Error.Invalid{} = error} = Config.delete_project(project)
    assert errors_on(error) == %{project_number: ["has runs and cannot be deleted"]}
  end

  test "event upserts replace payloads and conversations follow their first event id" do
    run = run_fixture(project_fixture(), "SHOP-1")
    Runs.record_note(run.id, "setup", %{"text" => "original"})
    Runs.record_note(run.id, "setup", %{"text" => "updated"})

    assert [%{payload: %{"text" => "updated"}}] = Runs.list_events(run.id)

    Runs.record_note(run.id, "second", %{"text" => "second"})
    [first, second] = Runs.list_events(run.id)

    # Conversation numbers deliberately differ from insertion order.
    first |> Ecto.Changeset.change(conversation: 9, role: "head") |> Repo.update!()
    second |> Ecto.Changeset.change(conversation: 1, role: "worker") |> Repo.update!()
    Runs.record_note(run.id, "third", %{"text" => "third"})

    assert Runs.conversations(run.id) == [{9, "head"}, {1, "worker"}, {0, "conductor"}]
  end
end
