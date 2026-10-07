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

  test "renders each status with its chip, links and actions", %{conn: conn, project: project} do
    run_fixture(project, "shop-1")
    run_fixture(project, "shop-2", %{status: :provisioning})
    run_fixture(project, "shop-3", %{status: :running})
    run_fixture(project, "shop-4", %{status: :waiting_for_input})
    run_fixture(project, "shop-5", %{status: :handing_off})

    run_fixture(project, "shop-6", %{
      status: :completed,
      pr_url: "https://github.com/acme/shop/pull/221"
    })

    run_fixture(project, "shop-7", %{status: :failed, error: "boom"})

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#runs-count", "7 of 7 runs")

    for {n, status, chip} <- [
          {1, "picked_up", "bg-muted"},
          {2, "provisioning", "bg-chip-info-bg"},
          {3, "running", "bg-chip-info-bg"},
          {4, "waiting_for_input", "bg-chip-warning-bg"},
          {5, "handing_off", "bg-chip-info-bg"},
          {6, "completed", "bg-chip-success-bg"},
          {7, "failed", "bg-chip-error-bg"}
        ] do
      id = "shop-#{n}-1"
      assert has_element?(view, ~s|#status-#{id}.#{chip}[data-status="#{status}"]|)
      assert has_element?(view, ~s|#runs-#{id} a#open-#{id}[href="/runs/#{id}"]|)
      assert has_element?(view, "#log-#{id}")
      assert has_element?(view, "#updated-#{id}")
    end

    assert has_element?(view, "#status-shop-4-1", "waiting for input")

    # Answer: on the run that waits for input only.
    assert has_element?(view, ~s|a#answer-shop-4-1[href="/runs/shop-4-1"]|)
    assert has_element?(view, "#runs-shop-4-1.bg-row-waiting")
    for n <- [1, 2, 3, 5, 6, 7], do: refute(has_element?(view, "#answer-shop-#{n}-1"))

    # The pull request, by its number.
    assert has_element?(
             view,
             ~s|a#pr-shop-6-1[href="https://github.com/acme/shop/pull/221"]|,
             "PR #221"
           )

    refute has_element?(view, "#pr-shop-7-1")

    # The error on the failed run.
    assert has_element?(view, "#error-shop-7-1", "boom")

    # Retry: on failed runs only.
    assert has_element?(view, "#retry-shop-7-1")
    for n <- 1..6, do: refute(has_element?(view, "#retry-shop-#{n}-1"))

    # Abort: until the run hands off.
    for n <- 1..4 do
      assert has_element?(view, "#abort-shop-#{n}-1")
      assert has_element?(view, "#confirm-abort-shop-#{n}-1")
    end

    for n <- 5..7, do: refute(has_element?(view, "#abort-shop-#{n}-1"))

    # No duration before the run starts.
    assert has_element?(view, "#duration-shop-1-1", "—")
    assert has_element?(view, "#duration-shop-3-1", "<1m")
    assert has_element?(view, "#duration-shop-6-1", "<1m")
  end

  test "shows the empty state and counts runs as they come in", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#runs-empty")
    assert has_element?(view, "#runs-count", "0 of 0 runs")

    run = run_fixture(project, "shop-1")
    assert has_element?(view, "#runs-count", "1 of 1 runs")

    transition_run(run, :running)
    assert has_element?(view, ~s|#status-shop-1-1[data-status="running"]|)
    assert has_element?(view, "#runs-count", "1 of 1 runs")
  end

  describe "filters" do
    setup %{project: project} do
      run_fixture(project, "shop-1", %{status: :running})

      run_fixture(project, "shop-2", %{
        status: :failed,
        error: "boom",
        issue_snapshot: snapshot("shop-2", "Fix the Checkout_page")
      })

      run_fixture(project, "shop-3", %{status: :completed})
      run_fixture(project, "shop-4")
      :ok
    end

    test "chips show true counts and filter by status group", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#filter-all[aria-pressed=true]", "4")
      assert has_element?(view, "#filter-count-running", "1")
      assert has_element?(view, "#filter-count-failed", "1")
      assert has_element?(view, "#runs-count", "4 of 4 runs")

      view |> element("#filter-failed") |> render_click()
      assert_patch(view, ~p"/?status=failed")
      assert has_element?(view, "#filter-failed[aria-pressed=true]")
      assert has_element?(view, "#filter-all[aria-pressed=false]")
      assert has_element?(view, "#open-shop-2-1")
      refute has_element?(view, "#open-shop-1-1")
      assert has_element?(view, "#runs-count", "1 of 4 runs")
      assert has_element?(view, "#filter-count-all", "4")
    end

    test "the text field matches run id and summary together with the chip", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> form("#runs-search-form", filter: %{q: "CHECKOUT_"}) |> render_change()
      assert_patch(view, ~p"/?q=CHECKOUT_")
      assert has_element?(view, "#open-shop-2-1")
      refute has_element?(view, "#open-shop-1-1")
      assert has_element?(view, "#runs-count", "1 of 4 runs")

      view |> form("#runs-search-form", filter: %{q: "shop-3"}) |> render_change()
      assert has_element?(view, "#open-shop-3-1")
      refute has_element?(view, "#open-shop-2-1")

      view |> element("#filter-failed") |> render_click()
      refute has_element?(view, "#open-shop-3-1")
      assert has_element?(view, "#runs-empty", "No runs match this filter.")
      assert has_element?(view, "#runs-count", "0 of 4 runs")
    end

    test "the filter lives in the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/?status=completed&q=shop")
      assert has_element?(view, "#filter-completed[aria-pressed=true]")
      assert has_element?(view, "#runs-search[value=shop]")
      assert has_element?(view, "#open-shop-3-1")
      refute has_element?(view, "#open-shop-2-1")
    end

    test "a live update outside the filter stays out of the table but counts", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/?status=failed")

      run_fixture(project, "shop-5", %{status: :running})
      refute has_element?(view, "#open-shop-5-1")
      assert has_element?(view, "#filter-count-running", "2")
      assert has_element?(view, "#filter-count-all", "5")
      assert has_element?(view, "#runs-count", "1 of 5 runs")

      Runs.fail(Runs.get_run!("shop-5-1"), %{error: "x"})
      assert has_element?(view, "#open-shop-5-1")
      assert has_element?(view, "#runs-count", "2 of 5 runs")
    end

    test "a run that leaves the filter is removed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/?status=running")
      assert has_element?(view, "#open-shop-1-1")

      Runs.fail(Runs.get_run!("shop-1-1"), %{error: "x"})
      refute has_element?(view, "#open-shop-1-1")
      assert has_element?(view, "#runs-count", "0 of 4 runs")
      assert has_element?(view, "#filter-count-failed", "2")

      send(view.pid, :tick)
      refute has_element?(view, "#open-shop-1-1")
    end
  end

  test "without any runs the empty state says so", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/?status=failed")
    assert has_element?(view, "#runs-empty", "No runs yet.")
  end

  test "refreshes the rows of runs under way on a tick", %{conn: conn, project: project} do
    run_fixture(project, "shop-1", %{status: :running})
    {:ok, view, _html} = live(conn, ~p"/")

    send(view.pid, :tick)
    assert has_element?(view, "#duration-shop-1-1", "<1m")
    assert has_element?(view, "#runs-count", "1 of 1 runs")
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
