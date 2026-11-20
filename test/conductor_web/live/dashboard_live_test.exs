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

  test "navigation and filters expose their active state through ARIA", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, ~s|#nav-runs[aria-current="page"]|)
    refute has_element?(view, "#nav-config[aria-current]")
    assert has_element?(view, ~s|#filter-all[aria-pressed="true"]|)

    view |> element("#filter-running") |> render_click()
    assert has_element?(view, ~s|#filter-running[aria-pressed="true"]|)
    assert has_element?(view, ~s|#filter-all[aria-pressed="false"]|)

    {:ok, config, _} = live(conn, ~p"/config")
    assert has_element?(config, ~s|#nav-config[aria-current="page"]|)
    refute has_element?(config, "#nav-runs[aria-current]")
  end

  test "the live log opens beside the table and closes from the panel and from the row", %{
    conn: conn,
    project: project
  } do
    run_fixture(project, "shop-1", %{status: :running})
    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "#live-log")
    assert has_element?(view, ~s|#log-shop-1-1[aria-pressed="false"]|)

    view |> element("#log-shop-1-1") |> render_click()
    assert has_element?(view, ~s|#live-log a[href="/runs/shop-1-1"]|)
    assert has_element?(view, "#log-empty")
    assert has_element?(view, ~s|#log-shop-1-1[aria-pressed="true"]|)

    view |> element("#log-close") |> render_click()
    refute has_element?(view, "#live-log")
    assert has_element?(view, ~s|#log-shop-1-1[aria-pressed="false"]|)

    view |> element("#log-shop-1-1") |> render_click()
    assert has_element?(view, "#live-log")
    view |> element("#log-shop-1-1") |> render_click()
    refute has_element?(view, "#live-log")
  end

  test "lists runs, streams the live log, and retries", %{conn: conn, project: project} do
    run = run_fixture(project, "shop-1", %{status: :failed, error: "boom"})
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "shop-1-1"
    assert html =~ "boom"

    view |> element("#log-shop-1-1") |> render_click()

    send_event = fn event ->
      Runs.ingest(%{
        "type" => "agent_event",
        "run_id" => run.id,
        "conversation" => 1,
        "role" => "head",
        "event" => event
      })
    end

    answer = %{
      "id" => 2,
      "kind" => "pi.assistant",
      "model" => [
        %{
          "role" => "assistant",
          "stopReason" => "toolUse",
          "content" => [
            %{"type" => "text", "text" => "Looking around"},
            %{
              "type" => "toolCall",
              "id" => "c1",
              "name" => "bash",
              "arguments" => %{"command" => "ls -la"}
            }
          ]
        }
      ]
    }

    send_event.(%{"type" => "update", "entries" => [answer]})
    assert has_element?(view, "#log-log-1", "Looking around")
    assert has_element?(view, "#log-log-2", "bash ls -la")

    live = %{"busy" => true, "message" => nil, "tools" => [], "inbox" => []}
    retry = %{"attempt" => 1, "at" => 123, "error" => "overloaded"}
    send_event.(%{"type" => "update", "live" => Map.put(live, "retry", retry)})
    assert has_element?(view, "#log-log-3", "retrying: overloaded")

    # The same retry in a later live state is not logged again; the next one is.
    send_event.(%{
      "type" => "update",
      "live" => Map.merge(live, %{"retry" => retry, "inbox" => [%{"id" => 3, "mode" => "steer"}]})
    })

    refute has_element?(view, "#log-log-4")

    send_event.(%{
      "type" => "update",
      "live" => Map.put(live, "retry", %{retry | "attempt" => 2, "at" => 456})
    })

    assert has_element?(view, "#log-log-4", "retrying: overloaded")

    view |> element("#retry-shop-1-1") |> render_click()
    assert render(view) =~ "Queued shop-1-2"
    eventually(fn -> assert render(view) =~ "shop-1-2" end)
  end

  test "only the latest failed attempt offers Retry, also across filters", %{
    conn: conn,
    project: project
  } do
    first = run_fixture(project, "shop-70", %{status: :failed})
    {:ok, view, _} = live(conn, ~p"/?status=failed")
    assert has_element?(view, "#retry-#{first.id}")

    second = run_fixture(project, "shop-70")
    refute has_element?(view, "#retry-#{first.id}")
    {:ok, _} = Runs.fail(second)
    assert has_element?(view, "#retry-#{second.id}")
    refute has_element?(view, "#retry-#{first.id}")

    {:ok, reloaded, _} = live(conn, ~p"/")
    refute has_element?(reloaded, "#retry-#{first.id}")
    assert has_element?(reloaded, "#retry-#{second.id}")
  end

  test "renders each status with its links and actions", %{conn: conn, project: project} do
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
    run_fixture(project, "shop-8", %{status: :merged})

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#runs-count", "8 of 8 runs")

    for {status, n} <-
          Enum.with_index(
            ~w(picked_up provisioning running waiting_for_input handing_off completed failed merged),
            1
          ) do
      id = "shop-#{n}-1"
      assert has_element?(view, ~s|#status-#{id}[data-status="#{status}"]|)
      assert has_element?(view, ~s|#runs-#{id} a#open-#{id}[href="/runs/#{id}"]|)
      assert has_element?(view, "#log-#{id}")
    end

    assert has_element?(view, "#status-shop-4-1", "Waiting for input")

    # Answer: on the run that waits for input only.
    assert has_element?(view, ~s|a#answer-shop-4-1[href="/runs/shop-4-1"]|)
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
    for n <- [1, 2, 3, 4, 5, 6, 8], do: refute(has_element?(view, "#retry-shop-#{n}-1"))

    # Abort: until the run hands off.
    for n <- 1..4 do
      assert has_element?(view, "#abort-shop-#{n}-1")
      assert has_element?(view, "#confirm-abort-shop-#{n}-1")
    end

    for n <- 5..7, do: refute(has_element?(view, "#abort-shop-#{n}-1"))

    # No duration before the run starts.
    assert has_element?(view, "#duration-shop-1-1", "—")
    assert has_element?(view, "#duration-shop-3-1", "<1m")
  end

  test "the table is a focusable region for the keyboard", %{conn: conn, project: project} do
    run_fixture(project, "shop-1", %{status: :running})
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(
             view,
             ~s|#runs-table[phx-hook$="RunsKeys"][tabindex="0"][aria-label*="Enter opens"]|
           )

    # What the keys click on: the open link and the log toggle of each row.
    assert has_element?(view, ~s|#runs > tr a[id^="open-"]|)
    assert has_element?(view, ~s|#runs > tr button[id^="log-"]|)
    assert has_element?(view, "#runs-hints kbd", "j")
  end

  test "shows the empty state and counts runs as they come in", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/?status=failed")
    assert has_element?(view, "#runs-empty", "No runs yet.")
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#runs-count", "0 of 0 runs")

    run = run_fixture(project, "shop-1")
    assert has_element?(view, "#runs-count", "1 of 1 runs")

    transition_run(run, :running)
    assert has_element?(view, ~s|#status-shop-1-1[data-status="running"]|)
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

  test "shows when GitHub was last checked and updates after a poll", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#github-checked", "GitHub not checked yet")
    assert has_element?(view, "#header-actions #poll-now", "Check GitHub")

    Conductor.Poller.poll()
    _ = :sys.get_state(Conductor.Poller)

    assert has_element?(view, "#github-checked", "GitHub checked")
    refute has_element?(view, "#github-checked", "every")

    Req.Test.stub(Conductor.GitHub, fn conn ->
      Req.Test.json(conn, %{"errors" => [%{"message" => "Bad credentials"}]})
    end)

    view |> element("#poll-now") |> render_click()
    _ = :sys.get_state(Conductor.Poller)
    _ = :sys.get_state(Conductor.Poller)

    assert has_element?(
             view,
             ~s|#github-checked[title*="Bad credentials"]|,
             "GitHub check failed"
           )
  end
end
