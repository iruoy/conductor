defmodule ConductorWeb.DashboardLiveTest do
  use ConductorWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Conductor.Fixtures
  alias Conductor.Runs

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    project = project_fixture(%{repo: repo_fixture(%{clone_url: git_remote(dir)})})
    settings_fixture()
    stub_github()
    start_workers(dir)
    %{project: project}
  end

  test "lists runs, streams the live log, and retries", %{conn: conn, project: project} do
    run = run_fixture(project, "shop-1", %{status: :failed, error: "boom"})
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "shop-1-1"
    assert html =~ "boom"

    view |> element("#log-shop-1-1") |> render_click()

    Runs.ingest(%{
      "type" => "agent_event",
      "run_id" => run.id,
      "conversation" => 1,
      "role" => "head",
      "event" => %{
        "type" => "tool_execution_start",
        "toolCallId" => "c1",
        "toolName" => "bash",
        "args" => %{"command" => "ls -la"}
      }
    })

    assert render(view) =~ "bash ls -la"

    view |> element("#retry-shop-1-1") |> render_click()
    assert render(view) =~ "Queued shop-1-2"
    eventually(fn -> assert render(view) =~ "shop-1-2" end)
  end

  test "shows when GitHub was last checked and updates after a poll", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#github-checked", "GitHub not checked yet")
    assert has_element?(view, "#header-actions #poll-now", "Check GitHub")

    Conductor.Poller.poll()
    _ = :sys.get_state(Conductor.Poller)

    assert has_element?(view, "#github-checked", "GitHub checked")
    assert has_element?(view, "#github-checked-dot.bg-dot-green")
    refute has_element?(view, "#github-checked", "every")

    Req.Test.stub(Conductor.GitHub, fn conn ->
      Req.Test.json(conn, %{"errors" => [%{"message" => "Bad credentials"}]})
    end)

    view |> element("#poll-now") |> render_click()
    _ = :sys.get_state(Conductor.Poller)
    _ = :sys.get_state(Conductor.Poller)

    assert has_element?(view, "#github-checked-dot.bg-dot-red")
    assert has_element?(view, ~s|#github-checked[title*="Bad credentials"]|)
  end
end
