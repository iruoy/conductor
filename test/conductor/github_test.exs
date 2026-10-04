defmodule Conductor.GitHubTest do
  use ExUnit.Case, async: false
  import Conductor.Fixtures, only: [github_project: 0]
  alias Conductor.GitHub

  @repo %{name: "shop-api", owner: "acme", slug: "shop"}
  @project %{
    repo: @repo,
    project_owner: "acme",
    project_number: 4,
    runner_login: "conductor-bot",
    pickup_status: "Ready for AI",
    active_status: "In Progress",
    handoff_status: "Review",
    done_status: "Done",
    item_filter: nil
  }

  defp item(number, fields \\ %{}) do
    Map.merge(
      %{
        "id" => "item-#{number}",
        "project" => %{"id" => "project-1"},
        "status" => %{"name" => "Ready for AI"},
        "size" => nil,
        "priority" => nil
      },
      fields
    )
  end

  defp issue(number, fields \\ %{}) do
    Map.merge(
      %{
        "number" => number,
        "title" => "Issue #{number}",
        "body" => nil,
        "state" => "OPEN",
        "repository" => %{"nameWithOwner" => "acme/shop"},
        "labels" => %{"nodes" => []},
        "assignees" => %{"nodes" => [%{"login" => "Conductor-Bot"}]},
        "parent" => nil,
        "blockedBy" => %{"nodes" => []}
      },
      fields
    )
  end

  # Answers the Meta query with the fixture project and every other operation with `fun.(query, variables)`.
  defp stub_graphql(fun) do
    Req.Test.stub(Conductor.GitHub, fn conn ->
      assert conn.request_path == "/graphql"
      assert ["Bearer gh-token"] = Plug.Conn.get_req_header(conn, "authorization")
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"query" => query, "variables" => variables} = JSON.decode!(body)

      data =
        if query =~ "query Meta",
          do: %{"repositoryOwner" => %{"projectV2" => github_project()}},
          else: fun.(query, variables)

      Req.Test.json(conn, %{"data" => data})
    end)
  end

  defp stub_items(nodes) do
    stub_graphql(fn query, variables ->
      assert query =~ "query Items"
      assert %{"owner" => "acme", "number" => 4} = variables
      page = %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => nodes}
      %{"repositoryOwner" => %{"projectV2" => %{"items" => page}}}
    end)
  end

  test "issue keys are the repository name and the issue number" do
    assert GitHub.issue_key(@project, 12) == "shop-api-12"
    assert GitHub.number("shop-api-12") == 12
  end

  test "pickup takes the runner's open issues in the pickup status, by priority" do
    priority = fn name -> %{"priority" => %{"name" => name}} end
    someone = %{"nodes" => [%{"login" => "someone"}]}

    stub_items([
      item(1, priority.("P2")) |> Map.put("content", issue(1)),
      item(2) |> Map.put("content", issue(2)),
      item(3, priority.("P0")) |> Map.put("content", issue(3)),
      item(4, %{"status" => %{"name" => "In Progress"}}) |> Map.put("content", issue(4)),
      item(5) |> Map.put("content", issue(5, %{"assignees" => someone})),
      item(6) |> Map.put("content", issue(6, %{"state" => "CLOSED"})),
      item(7) |> Map.put("content", issue(7, %{"repository" => %{"nameWithOwner" => "acme/x"}})),
      # A pull request or a draft has no issue fields.
      item(8) |> Map.put("content", %{})
    ])

    assert {:ok, issues} = GitHub.pickup(@project)
    assert [3, 1, 2] = Enum.map(issues, & &1["number"])

    assert [
             %{
               "key" => "#3",
               "priority" => "P0",
               "priority_rank" => 0,
               "status" => "Ready for AI"
             }
             | _
           ] = issues

    assert List.last(issues)["priority_rank"] == 3
  end

  test "pickup respects relationships before priority" do
    blocked_by = fn state ->
      %{"blockedBy" => %{"nodes" => [%{"number" => 9, "state" => state, "repository" => %{}}]}}
    end

    runner = %{"nodes" => [%{"login" => "conductor-bot"}]}

    parent = fn state, assignees ->
      %{"parent" => %{"state" => state, "assignees" => assignees}}
    end

    p0 = %{"priority" => %{"name" => "P0"}}

    stub_items([
      item(1, p0) |> Map.put("content", issue(1, blocked_by.("OPEN"))),
      item(2) |> Map.put("content", issue(2, blocked_by.("CLOSED"))),
      item(3, p0) |> Map.put("content", issue(3, parent.("OPEN", runner))),
      item(4) |> Map.put("content", issue(4, parent.("OPEN", %{"nodes" => []}))),
      item(5) |> Map.put("content", issue(5, parent.("CLOSED", runner)))
    ])

    assert {:ok, issues} = GitHub.pickup(@project)
    assert [2, 4, 5] = Enum.map(issues, & &1["number"])
  end

  test "pickup follows the pages of the project and passes the filter" do
    stub_graphql(fn _query, variables ->
      assert variables["filter"] == "is:open"

      {nodes, page} =
        case variables["cursor"] do
          nil ->
            {[item(1) |> Map.put("content", issue(1))],
             %{"hasNextPage" => true, "endCursor" => "c1"}}

          "c1" ->
            {[item(2) |> Map.put("content", issue(2))], %{"hasNextPage" => false}}
        end

      %{
        "repositoryOwner" => %{
          "projectV2" => %{"items" => %{"pageInfo" => page, "nodes" => nodes}}
        }
      }
    end)

    assert {:ok, [%{"number" => 1}, %{"number" => 2}]} =
             GitHub.pickup(%{@project | item_filter: "is:open"})
  end

  test "issue returns a snapshot with the sub-issues by priority, their size and dependencies" do
    sub = fn number, fields, item_fields ->
      issue(number, fields) |> Map.put("projectItems", %{"nodes" => [item(number, item_fields)]})
    end

    blocker = %{
      "number" => 2,
      "state" => "OPEN",
      "repository" => %{"nameWithOwner" => "acme/shop"}
    }

    elsewhere = %{
      "number" => 7,
      "state" => "OPEN",
      "repository" => %{"nameWithOwner" => "acme/x"}
    }

    stub_graphql(fn query, variables ->
      assert query =~ "query Issue"
      assert variables == %{"owner" => "acme", "name" => "shop", "number" => 1}

      parent =
        issue(1, %{
          "title" => "Parent",
          "body" => "Make it fast",
          "issueType" => %{"name" => "Feature"},
          "labels" => %{"nodes" => [%{"name" => "backend"}]},
          "projectItems" => %{
            "nodes" => [
              %{"id" => "other", "project" => %{"id" => "project-9"}},
              item(1, %{"priority" => %{"name" => "P1"}})
            ]
          },
          "subIssues" => %{
            "nodes" => [
              sub.(
                3,
                %{"blockedBy" => %{"nodes" => [blocker, elsewhere]}},
                %{"size" => %{"name" => "M"}, "priority" => %{"name" => "P2"}}
              ),
              sub.(
                2,
                %{"labels" => %{"nodes" => [%{"name" => "bug"}]}},
                %{"size" => %{"name" => "XS"}, "priority" => %{"name" => "P0"}}
              ),
              issue(4, %{"projectItems" => %{"nodes" => []}}),
              sub.(9, %{"repository" => %{"nameWithOwner" => "acme/x"}}, %{})
            ]
          }
        })

      %{"repository" => %{"issue" => parent}}
    end)

    assert {:ok, issue} = GitHub.issue(@project, 1)

    assert %{
             "key" => "#1",
             "number" => 1,
             "summary" => "Parent",
             "type" => "Feature",
             "labels" => ["backend"],
             "description" => "Make it fast",
             "priority" => "P1",
             "priority_rank" => 1,
             "item_id" => "item-1"
           } = issue

    assert [
             %{
               "key" => "#2",
               "type" => "Bug",
               "size" => "XS",
               "priority_rank" => 0,
               "blocked_by" => []
             },
             %{"key" => "#3", "size" => "M", "blocked_by" => ["#2"], "status" => "Ready for AI"},
             %{
               "key" => "#4",
               "size" => nil,
               "item_id" => nil,
               "status" => "open",
               "priority_rank" => 3
             }
           ] = issue["subtasks"]

    assert {:ok,
            %{
              repo: "acme/shop",
              project_id: "project-1",
              status_field_id: "status-field",
              done_status: "Done"
            } = context} =
             GitHub.run_context(@project, issue)

    assert context.items == %{"1" => "item-1", "2" => "item-2", "3" => "item-3"}
    assert context.statuses["In Progress"] == "option:In Progress"
  end

  test "transition sets the Status field and is a no-op when already there" do
    test = self()

    stub_graphql(fn query, variables ->
      cond do
        query =~ "query Item" ->
          %{
            "repository" => %{
              "issue" => %{"projectItems" => %{"nodes" => [item(variables["number"])]}}
            }
          }

        query =~ "mutation SetStatus" ->
          send(test, {:set, variables})
          %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "item-1"}}}
      end
    end)

    assert {:ok, :transitioned} = GitHub.transition(@project, 1, "in progress")

    assert_received {:set,
                     %{
                       "project" => "project-1",
                       "item" => "item-1",
                       "field" => "status-field",
                       "option" => "option:In Progress"
                     }}

    assert {:ok, :unchanged} = GitHub.transition(@project, 1, "ready for ai")
    refute_received {:set, _}

    assert {:error, "GitHub project acme/4 has no status Blocked"} =
             GitHub.transition(@project, 1, "Blocked")
  end

  test "reports GraphQL errors and a missing project" do
    Req.Test.stub(Conductor.GitHub, fn conn ->
      Req.Test.json(conn, %{"data" => nil, "errors" => [%{"message" => "Bad credentials"}]})
    end)

    assert {:error, "GitHub: Bad credentials"} = GitHub.pickup(@project)

    Req.Test.stub(Conductor.GitHub, fn conn ->
      Req.Test.json(conn, %{"data" => %{"repositoryOwner" => nil}})
    end)

    assert {:error, "GitHub project acme/4 was not found"} = GitHub.pickup(@project)
  end

  test "branch_exists?" do
    Req.Test.stub(Conductor.GitHub, fn conn ->
      case conn.request_path do
        "/repos/acme/shop/branches/feature/1" -> Req.Test.json(conn, %{"name" => "feature/1"})
        _ -> conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end
    end)

    assert {:ok, true} = GitHub.branch_exists?(@repo, "feature/1")
    assert {:ok, false} = GitHub.branch_exists?(@repo, "feature/2")
  end

  test "find_or_create_pr reuses an open PR" do
    Req.Test.stub(Conductor.GitHub, fn conn ->
      assert conn.method == "GET"
      assert %{"head" => "acme:feature/1", "state" => "open"} = conn.query_params
      Req.Test.json(conn, [%{"html_url" => "https://github.com/acme/shop/pull/1"}])
    end)

    assert {:ok, "https://github.com/acme/shop/pull/1"} =
             GitHub.find_or_create_pr(@repo, "feature/1", "main", "[#1] T")
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
             GitHub.find_or_create_pr(@repo, "feature/1", "staging", "[#1] T", "body")

    assert_received {:created,
                     %{
                       "title" => "[#1] T",
                       "head" => "feature/1",
                       "base" => "staging",
                       "body" => "body"
                     }}
  end

  test "reports missing configuration instead of crashing" do
    config = Application.get_env(:conductor, Conductor.GitHub)
    Application.put_env(:conductor, Conductor.GitHub, Keyword.put(config, :token, nil))
    on_exit(fn -> Application.put_env(:conductor, Conductor.GitHub, config) end)
    assert {:error, "GitHub is not configured" <> _} = GitHub.transition(@project, 1, "Review")
  end
end
