defmodule ConductorWeb.ConfigLiveTest do
  use ConductorWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Conductor.Fixtures
  alias Conductor.Config

  @moduletag :tmp_dir

  test "manages repositories, projects, and settings", %{conn: conn, tmp_dir: dir} do
    start_workers(dir)
    {:ok, view, _html} = live(conn, ~p"/config")

    view |> element("#new-repo") |> render_click()

    view
    |> form("#repo-form",
      repository: %{
        name: "shop",
        clone_url: "git@x:acme/shop.git",
        owner: "acme",
        slug: "shop"
      }
    )
    |> render_submit()

    assert [%{name: "shop"} = repo] = Config.list_repos()

    view |> element("#new-project") |> render_click()

    view
    |> form("#project-form",
      project: %{
        project_owner: "acme",
        project_number: "4",
        repo_id: repo.id,
        runner_login: "conductor-bot",
        pickup_status: "Ready",
        active_status: "In Progress",
        handoff_status: "Review"
      }
    )
    |> render_submit()

    assert [%{project_owner: "acme", project_number: 4, done_status: "Done"}] =
             Config.list_projects()

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
  end
end
