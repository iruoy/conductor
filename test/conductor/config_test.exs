defmodule Conductor.ConfigTest do
  use Conductor.DataCase, async: true
  import Conductor.Fixtures
  alias Conductor.Config
  alias Conductor.Config.{Project, Repository, Settings}

  test "the domain registers resources on the existing tables" do
    assert Ash.Domain.Info.resources(Config) == [Repository, Project, Settings]

    for {resource, table} <- [
          {Repository, "repos"},
          {Project, "projects"},
          {Settings, "settings"}
        ] do
      assert AshPostgres.DataLayer.Info.table(resource) == table
      assert Ash.Resource.Info.attribute(resource, :id).type == Ash.Type.Integer
    end
  end

  test "repository attributes round-trip and names are required, formatted, and unique" do
    repo = repo_fixture(%{base_branch: "main", setup_script: "echo ready"})

    assert Map.take(Config.get_repo!(repo.id), [
             :id,
             :name,
             :clone_url,
             :base_branch,
             :setup_script
           ]) ==
             Map.take(repo, [:id, :name, :clone_url, :base_branch, :setup_script])

    assert repo.base_branch == "main"
    assert repo.setup_script == "echo ready"

    assert {:error, changeset} = Config.create_repo(%{})
    assert Map.keys(errors_on(changeset)) |> Enum.sort() == [:clone_url, :name, :owner, :slug]

    assert {:error, changeset} = Config.update_repo(repo, %{name: "invalid name"})
    assert errors_on(changeset).name == ["letters, digits, dots, dashes and underscores only"]

    assert {:error, changeset} =
             Config.create_repo(Map.take(repo, [:name, :clone_url, :owner, :slug]))

    assert errors_on(changeset).name == ["has already been taken"]
  end

  test "projects load repositories, preserve defaults, and have an enabled read" do
    project = project_fixture(%{item_filter: "label:bug"})
    disabled = project_fixture(%{enabled: false})
    assert project.done_status == "Done"
    assert project.enabled
    assert project.item_filter == "label:bug"
    assert Config.get_project!(project.id).repo.id == project.repo_id
    assert Enum.map(Config.list_enabled_projects(), & &1.id) == [project.id]
    assert Enum.all?(Config.list_projects(), &match?(%Repository{}, &1.repo))
    assert Config.get_project!(disabled.id).enabled == false
  end

  test "projects require their fields and positive numbers and report identity errors on number" do
    project = project_fixture()

    assert {:error, changeset} = Config.create_project(%{})

    assert Map.keys(errors_on(changeset)) |> Enum.sort() ==
             [
               :active_status,
               :handoff_status,
               :pickup_status,
               :project_number,
               :project_owner,
               :repo_id,
               :runner_login
             ]

    assert {:error, changeset} = Config.update_project(project, %{project_number: 0})
    assert Map.has_key?(errors_on(changeset), :project_number)
    assert {:error, changeset} = Config.update_project(project, %{done_status: ""})
    assert Map.has_key?(errors_on(changeset), :done_status)

    attrs =
      Map.take(project, [
        :repo_id,
        :project_owner,
        :project_number,
        :runner_login,
        :pickup_status,
        :active_status,
        :handoff_status
      ])

    assert {:error, changeset} = Config.create_project(attrs)

    assert errors_on(changeset) == %{
             project_number: ["is already configured for this repository"]
           }
  end

  test "get_settings creates the singleton with defaults and settings validate bounds" do
    settings = Config.get_settings()
    assert Config.get_settings().id == settings.id
    assert settings.models == %{}
    assert settings.max_concurrent == 3
    assert settings.prune_days == 7
    assert Config.run_models(settings) == nil

    for maximum <- [0, 20] do
      assert {:ok, %{max_concurrent: ^maximum}} =
               Config.update_settings(settings, %{max_concurrent: maximum})
    end

    for maximum <- [-1, 21] do
      assert {:error, changeset} = Config.update_settings(settings, %{max_concurrent: maximum})
      assert Map.has_key?(errors_on(changeset), :max_concurrent)
    end

    assert {:error, changeset} = Config.update_settings(settings, %{prune_days: 0})
    assert Map.has_key?(errors_on(changeset), :prune_days)
  end

  test "models normalize roles and persist exactly the runner JSON shape" do
    models = %{
      "head" => %{
        "provider" => "faux",
        "modelId" => "head-1",
        "reasoning" => "high",
        "extra" => true
      },
      "low" => %{"provider" => "", "modelId" => "low-1", "reasoning" => nil},
      "medium" => %{"modelId" => ""},
      "high" => %{"provider" => "faux"},
      "unknown" => %{"modelId" => "ignored"}
    }

    assert {:ok, settings} = Config.update_settings(Config.get_settings(), %{models: models})

    expected = %{
      "head" => %{"provider" => "faux", "modelId" => "head-1", "reasoning" => "high"},
      "low" => %{"modelId" => "low-1"}
    }

    assert settings.models == expected
    assert Config.get_settings().models == expected

    assert %{rows: [[^expected]]} =
             Repo.query!("SELECT models FROM settings WHERE id = $1", [settings.id])

    assert Settings.roles() == ~w(head low medium high)

    assert Config.run_models(settings) ==
             Map.merge(expected, %{"medium" => expected["head"], "high" => expected["head"]})
  end

  test "Ecto Run belongs_to the Ash Project still loads through the public API" do
    project = project_fixture()
    run = run_fixture(project, "shop-8")
    loaded = Conductor.Runs.get_run!(run.id)
    assert loaded.project.id == project.id
    assert loaded.project.repo.id == project.repo_id
    assert [%{project: %{repo: %Repository{}}}] = Conductor.Runs.list_by_status(["picked_up"])
  end
end
