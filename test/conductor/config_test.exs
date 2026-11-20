defmodule Conductor.ConfigTest do
  use Conductor.DataCase, async: true
  import Conductor.Fixtures
  alias Conductor.Config
  alias Conductor.Config.{Project, Repository}

  test "repository names are required, formatted and unique" do
    repo = repo_fixture()

    assert {:error, error} = Ash.create(Repository, %{})
    assert Map.keys(errors_on(error)) |> Enum.sort() == [:clone_url, :name, :owner, :slug]

    assert {:error, error} = Ash.update(repo, %{name: "invalid name"})
    assert errors_on(error).name == ["letters, digits, dots, dashes and underscores only"]

    assert {:error, error} =
             Ash.create(Repository, Map.take(repo, [:name, :clone_url, :owner, :slug]))

    assert errors_on(error).name == ["has already been taken"]
  end

  test "projects default their done status and only enabled ones are polled" do
    project = project_fixture()
    disabled = project_fixture(%{enabled: false})
    assert project.done_status == "Done"
    assert Enum.map(Config.list_enabled_projects(), & &1.id) == [project.id]
    assert Config.get_project!(disabled.id).repo.id == disabled.repo_id
  end

  test "projects validate their number, statuses and uniqueness per repository" do
    project = project_fixture()

    assert {:error, error} = Ash.update(project, %{project_number: 0})
    assert Map.has_key?(errors_on(error), :project_number)
    assert {:error, error} = Ash.update(project, %{done_status: ""})
    assert Map.has_key?(errors_on(error), :done_status)

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

    assert {:error, error} = Ash.create(Project, attrs)
    assert errors_on(error) == %{project_number: ["is already configured for this repository"]}
  end

  test "a repository with projects and a project with runs cannot be deleted" do
    project = project_fixture()
    assert {:error, error} = Config.delete_repo(project.repo)
    assert errors_on(error) == %{name: ["is used by a project"]}

    run_fixture(project, "SHOP-1")
    assert {:error, error} = Config.delete_project(project)
    assert errors_on(error) == %{project_number: ["has runs and cannot be deleted"]}
  end

  test "settings are a singleton with defaults and bounded limits" do
    settings = Config.get_settings()
    assert Config.get_settings().id == settings.id
    assert %{models: %{}, max_concurrent: 3, prune_days: 7} = settings
    assert Config.run_models(settings) == nil

    for maximum <- [0, 20],
        do: assert({:ok, _} = Ash.update(settings, %{max_concurrent: maximum}))

    for attrs <- [%{max_concurrent: -1}, %{max_concurrent: 21}, %{prune_days: 0}] do
      assert {:error, %Ash.Error.Invalid{}} = Ash.update(settings, attrs)
    end
  end

  test "models keep the known roles in the runner's shape and fall back to the head" do
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

    assert {:ok, settings} = Ash.update(Config.get_settings(), %{models: models})

    expected = %{
      "head" => %{"provider" => "faux", "modelId" => "head-1", "reasoning" => "high"},
      "low" => %{"modelId" => "low-1"}
    }

    assert Config.get_settings().models == expected

    assert Config.run_models(settings) ==
             Map.merge(expected, %{"medium" => expected["head"], "high" => expected["head"]})
  end
end
