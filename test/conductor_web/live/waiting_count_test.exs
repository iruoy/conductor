defmodule ConductorWeb.WaitingCountTest do
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

  test "no counter without waiting runs", %{conn: conn, project: project} do
    run_fixture(project, "shop-1", %{status: :running})
    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "#nav-waiting-count")
  end

  test "the counter shows on every page and follows runs live", %{conn: conn, project: project} do
    run = run_fixture(project, "shop-1", %{status: :waiting_for_input})

    for path <- [~p"/", ~p"/runs/#{run.id}", ~p"/config"] do
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, "#nav-waiting-count[title='1 run waiting for input']", "1")
    end

    {:ok, view, _html} = live(conn, ~p"/config")
    other = run_fixture(project, "shop-2", %{status: :running})
    {:ok, other} = Runs.wait_for_input(other)
    assert has_element?(view, "#nav-waiting-count[title='2 runs waiting for input']", "2")

    {:ok, _} = Runs.resume(run)
    {:ok, _} = Runs.resume(other)
    refute has_element?(view, "#nav-waiting-count")
  end

  test "the run page still follows its own run", %{conn: conn, project: project} do
    run = run_fixture(project, "shop-1", %{status: :waiting_for_input})
    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
    other = run_fixture(project, "shop-2", %{status: :running})
    {:ok, _} = Runs.wait_for_input(other)
    assert has_element?(view, "#nav-waiting-count", "2")
    assert render(view) =~ run.id
  end
end
