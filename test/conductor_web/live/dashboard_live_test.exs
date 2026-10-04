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
    run = run_fixture(project, "SHOP-1", %{status: "failed", error: "boom"})
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "SHOP-1-1"
    assert html =~ "boom"

    view |> element("#log-SHOP-1-1") |> render_click()

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

    view |> element("#retry-SHOP-1-1") |> render_click()
    assert render(view) =~ "Queued SHOP-1-2"
    eventually(fn -> assert render(view) =~ "SHOP-1-2" end)
  end
end
