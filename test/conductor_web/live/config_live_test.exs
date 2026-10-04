defmodule ConductorWeb.ConfigLiveTest do
  use ConductorWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Conductor.Fixtures
  alias Conductor.Config

  @moduletag :tmp_dir

  test "manages repositories, projects, and settings", %{conn: conn, tmp_dir: dir} do
    stub_github()
    start_workers(dir)
    {:ok, view, _html} = live(conn, ~p"/config")

    view |> element("#new-repo") |> render_click()

    # Choosing one of the token account's repositories fills in where it lives.
    view
    |> form("#repo-form")
    |> render_change(%{"_target" => ["repository", "github"], repository: %{github: "acme/shop"}})

    view |> form("#repo-form", repository: %{test_command: "mix test"}) |> render_submit()

    assert [
             %{
               name: "shop",
               owner: "acme",
               slug: "shop",
               clone_url: "git@github.com:acme/shop.git",
               test_command: "mix test"
             } = repo
           ] = Config.list_repos()

    view |> element("#new-project") |> render_click()

    # Choosing one of the account's projects fills in the project, the runner and a guess at the statuses.
    view
    |> form("#project-form")
    |> render_change(%{"_target" => ["project", "github"], project: %{github: "acme/1"}})

    assert has_element?(view, "select#project_pickup_status option[selected]", "Ready for AI")
    view |> form("#project-form", project: %{repo_id: repo.id}) |> render_submit()

    assert [
             %{
               project_owner: "acme",
               project_number: 1,
               runner_login: "conductor-bot",
               pickup_status: "Ready for AI",
               active_status: "In Progress",
               handoff_status: "Review",
               done_status: "Done"
             }
           ] = Config.list_projects()

    # Model choices come from the runner.
    assert render(view) =~ "Faux 1"

    view
    |> form("#settings-form",
      settings: %{
        max_concurrent: "2",
        models: %{head: %{model: "faux/faux-1", reasoning: "high"}}
      }
    )
    |> render_submit()

    settings = Config.get_settings()
    assert settings.max_concurrent == 2

    assert settings.models == %{
             "head" => %{"provider" => "faux", "modelId" => "faux-1", "reasoning" => "high"}
           }

    # Deleting asks first, in a dialog.
    [project] = Config.list_projects()
    assert has_element?(view, "dialog#confirm-delete-project-#{project.id}")
    view |> element("#confirm-delete-project-#{project.id}-confirm") |> render_click()
    assert Config.list_projects() == []

    view |> element("#confirm-delete-repo-#{repo.id}-confirm") |> render_click()
    assert Config.list_repos() == []
  end

  test "validates and updates repository and project Ash forms", %{conn: conn, tmp_dir: dir} do
    stub_github()
    start_workers(dir)
    repo = repo_fixture()
    project = project_fixture(%{repo: repo})
    {:ok, view, _} = live(conn, ~p"/config")

    view |> element("#edit-repo-#{repo.id}") |> render_click()
    view |> form("#repo-form", repository: %{name: "invalid name"}) |> render_change()
    assert has_element?(view, "#repo-form", "letters, digits, dots, dashes and underscores only")
    view |> form("#repo-form", repository: %{name: "invalid name"}) |> render_submit()
    assert Config.get_repo!(repo.id).name == repo.name
    assert has_element?(view, "#repo-form")
    view |> form("#repo-form", repository: %{name: "updated"}) |> render_submit()
    refute has_element?(view, "#repo-form")
    assert Config.get_repo!(repo.id).name == "updated"

    view |> element("#edit-project-#{project.id}") |> render_click()
    view |> form("#project-form", project: %{project_number: "0"}) |> render_change()
    assert has_element?(view, "#project-form", "must be greater than 0")
    view |> form("#project-form", project: %{project_number: "0"}) |> render_submit()
    assert Config.get_project!(project.id).project_number == 1
    view |> form("#project-form", project: %{project_number: "2"}) |> render_submit()
    refute has_element?(view, "#project-form")
    assert Config.get_project!(project.id).project_number == 2
  end

  test "typed model forms retain choices on errors and support fallback and saved models", %{
    conn: conn,
    tmp_dir: dir
  } do
    stub_github()
    start_workers(dir)

    settings_fixture(%{
      models: %{
        "head" => %{"provider" => "saved", "modelId" => "unlisted", "reasoning" => "medium"}
      }
    })

    {:ok, view, _} = live(conn, ~p"/config")
    assert has_element?(view, "#model-head option[value='saved/unlisted'][selected]")
    assert has_element?(view, "#reasoning-head option[value='medium'][selected]")

    params = %{
      max_concurrent: "21",
      prune_days: "0",
      models: %{
        head: %{model: "faux/faux-1", reasoning: "high"},
        low: %{model: "faux/faux-1", reasoning: "low"}
      }
    }

    view |> form("#settings-form", settings: params) |> render_submit()
    assert has_element?(view, "#settings-form", "must be less than or equal to 20")
    assert has_element?(view, "#model-head option[value='faux/faux-1'][selected]")
    assert has_element?(view, "#reasoning-low option[value='low'][selected]")
    assert Config.get_settings().models["head"]["provider"] == "saved"

    view
    |> form("#settings-form", settings: %{params | max_concurrent: "0", prune_days: "5"})
    |> render_submit()

    settings = Config.get_settings()
    assert settings.max_concurrent == 0
    assert settings.prune_days == 5
    assert settings.models["low"]["reasoning"] == "low"
    assert Config.run_models(settings)["medium"] == settings.models["head"]

    view
    |> form("#settings-form", settings: %{models: %{low: %{model: "", reasoning: ""}}})
    |> render_submit()

    refute Map.has_key?(Config.get_settings().models, "low")
  end

  test "delete failures remain visible and preserve records", %{conn: conn, tmp_dir: dir} do
    stub_github()
    start_workers(dir)
    project = project_fixture()
    run_fixture(project, "shop-99")
    {:ok, view, _} = live(conn, ~p"/config")

    view |> element("#confirm-delete-repo-#{project.repo_id}-confirm") |> render_click()
    assert has_element?(view, "#flash-error", "This repository is used by a project")
    assert has_element?(view, "#edit-repo-#{project.repo_id}")
    view |> element("#confirm-delete-project-#{project.id}-confirm") |> render_click()
    assert has_element?(view, "#flash-error", "This project has runs and cannot be deleted")
    assert has_element?(view, "#edit-project-#{project.id}")
  end
end
