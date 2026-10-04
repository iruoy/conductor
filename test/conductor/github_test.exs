defmodule Conductor.GitHubTest do
  use ExUnit.Case, async: false
  alias Conductor.GitHub

  @repo %{owner: "acme", slug: "shop"}
  @project %{
    key: "SHOP",
    repo: @repo,
    runner_login: "conductor-bot",
    pickup_label: "Ready",
    active_label: "In Progress",
    handoff_label: "Review",
    search_extra: "label:ai"
  }

  test "pickup_query filters on the repository, the runner and the pickup label" do
    assert GitHub.pickup_query(@project) ==
             ~s|repo:acme/shop is:issue is:open assignee:conductor-bot label:"Ready" label:ai|

    assert GitHub.pickup_query(%{@project | search_extra: nil}) ==
             ~s|repo:acme/shop is:issue is:open assignee:conductor-bot label:"Ready"|
  end

  test "search sends the query and keys the issues by project" do
    Req.Test.stub(Conductor.GitHub, fn conn ->
      assert conn.request_path == "/search/issues"
      assert conn.query_params["q"] == "repo:acme/shop is:open"
      assert ["Bearer gh-token"] = Plug.Conn.get_req_header(conn, "authorization")
      Req.Test.json(conn, %{"items" => [%{"number" => 1, "title" => "S", "state" => "open"}]})
    end)

    assert {:ok, [%{"key" => "SHOP-1", "number" => 1, "summary" => "S", "status" => "open"}]} =
             GitHub.search(@project, "repo:acme/shop is:open")
  end

  test "issue returns a snapshot with sub-issues, labels, dependencies and the type" do
    Req.Test.stub(Conductor.GitHub, fn conn ->
      case conn.request_path do
        "/repos/acme/shop/issues/1" ->
          Req.Test.json(conn, %{
            "number" => 1,
            "title" => "Parent",
            "body" => "Make it fast",
            "state" => "open",
            "type" => %{"name" => "Feature"},
            "labels" => [%{"name" => "backend"}]
          })

        "/repos/acme/shop/issues/1/sub_issues" ->
          Req.Test.json(conn, [
            %{
              "number" => 2,
              "title" => "Child",
              "body" => nil,
              "state" => "open",
              "labels" => [%{"name" => "complexity:low"}, %{"name" => "bug"}],
              "repository_url" => "https://api.github.com/repos/acme/shop"
            },
            %{
              "number" => 9,
              "title" => "Elsewhere",
              "state" => "open",
              "repository_url" => "https://api.github.com/repos/acme/other"
            }
          ])

        "/repos/acme/shop/issues/2/dependencies/blocked_by" ->
          Req.Test.json(conn, [%{"number" => 3}])
      end
    end)

    assert {:ok, issue} = GitHub.issue(@project, "SHOP-1")

    assert %{
             "key" => "SHOP-1",
             "summary" => "Parent",
             "type" => "Feature",
             "labels" => ["backend"],
             "description" => "Make it fast"
           } = issue

    assert [
             %{
               "key" => "SHOP-2",
               "number" => 2,
               "type" => "Bug",
               "labels" => ["complexity:low", "bug"],
               "blocked_by" => ["SHOP-3"],
               "status" => "open",
               "description" => ""
             }
           ] = issue["subtasks"]
  end

  test "transition swaps the status label and is a no-op when already there" do
    test = self()

    Req.Test.stub(Conductor.GitHub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/repos/acme/shop/issues/1"} ->
          Req.Test.json(conn, %{"labels" => [%{"name" => "Ready"}, %{"name" => "backend"}]})

        {"DELETE", "/repos/acme/shop/issues/1/labels/" <> label} ->
          send(test, {:removed, label})
          Req.Test.json(conn, [])

        {"POST", "/repos/acme/shop/issues/1/labels"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:added, JSON.decode!(body)})
          Req.Test.json(conn, [])
      end
    end)

    assert {:ok, :transitioned} = GitHub.transition(@project, "SHOP-1", "In Progress")
    assert_received {:removed, "Ready"}
    assert_received {:added, %{"labels" => ["In Progress"]}}
    assert {:ok, :unchanged} = GitHub.transition(@project, "SHOP-1", "ready")
    refute_received {:removed, _}
  end

  test "branch_exists?" do
    Req.Test.stub(Conductor.GitHub, fn conn ->
      case conn.request_path do
        "/repos/acme/shop/branches/feature/X-1" -> Req.Test.json(conn, %{"name" => "feature/X-1"})
        _ -> conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end
    end)

    assert {:ok, true} = GitHub.branch_exists?(@repo, "feature/X-1")
    assert {:ok, false} = GitHub.branch_exists?(@repo, "feature/X-2")
  end

  test "find_or_create_pr reuses an open PR" do
    Req.Test.stub(Conductor.GitHub, fn conn ->
      assert conn.method == "GET"
      assert %{"head" => "acme:feature/X-1", "state" => "open"} = conn.query_params
      Req.Test.json(conn, [%{"html_url" => "https://github.com/acme/shop/pull/1"}])
    end)

    assert {:ok, "https://github.com/acme/shop/pull/1"} =
             GitHub.find_or_create_pr(@repo, "feature/X-1", "main", "[X-1] T")
  end

  test "find_or_create_pr creates one into the base branch" do
    test = self()

    Req.Test.stub(Conductor.GitHub, fn
      %{method: "GET"} = conn ->
        Req.Test.json(conn, [])

      %{method: "POST"} = conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:created, JSON.decode!(body)})
        Req.Test.json(conn, %{"html_url" => "https://github.com/acme/shop/pull/2"})
    end)

    assert {:ok, "https://github.com/acme/shop/pull/2"} =
             GitHub.find_or_create_pr(@repo, "feature/X-1", "staging", "[X-1] T", "body")

    assert_received {:created,
                     %{
                       "title" => "[X-1] T",
                       "head" => "feature/X-1",
                       "base" => "staging",
                       "body" => "body"
                     }}
  end

  test "reports missing configuration instead of crashing" do
    config = Application.get_env(:conductor, Conductor.GitHub)
    Application.put_env(:conductor, Conductor.GitHub, Keyword.put(config, :token, nil))
    on_exit(fn -> Application.put_env(:conductor, Conductor.GitHub, config) end)

    assert {:error, "GitHub is not configured" <> _} =
             GitHub.transition(@project, "SHOP-1", "Review")
  end
end
