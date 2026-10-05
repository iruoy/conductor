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

    # Choosing a model offers its reasoning levels and selects its default one.
    view
    |> form("#settings-form", settings: %{models: %{head: %{model: "faux/faux-1"}}})
    |> render_change(%{"_target" => ["settings", "models", "head", "model"]})

    assert has_element?(view, "#reasoning-head option[value=high][selected]")
    assert has_element?(view, "#reasoning-head option[value=low]")
    refute has_element?(view, "#reasoning-head option[value=medium]")
    # A chosen model always has a level; only a role without a model can leave it unset.
    refute has_element?(view, "#reasoning-head option[value='']")
    assert has_element?(view, "#reasoning-low option[value='']")

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
end
