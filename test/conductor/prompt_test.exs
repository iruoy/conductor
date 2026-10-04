defmodule Conductor.PromptTest do
  use ExUnit.Case, async: true
  alias Conductor.Prompt

  @repo %Conductor.Config.Repository{
    name: "shop",
    owner: "acme",
    slug: "shop",
    test_command: "mix test"
  }

  test "renders the issue, subtasks with complexity and dependencies, and the rules" do
    issue = %{
      "key" => "SHOP-1",
      "summary" => "Checkout",
      "type" => "Story",
      "labels" => [],
      "description" => "Build checkout.",
      "subtasks" => [
        %{
          "key" => "SHOP-2",
          "number" => 2,
          "summary" => "API",
          "status" => "open",
          "labels" => ["complexity:low"],
          "blocked_by" => [],
          "description" => ""
        },
        %{
          "key" => "SHOP-3",
          "number" => 3,
          "summary" => "UI",
          "status" => "open",
          "labels" => [],
          "blocked_by" => ["SHOP-2"],
          "description" => "Pages"
        }
      ]
    }

    prompt = Prompt.render(issue, @repo, "feature/SHOP-1", "staging")
    assert prompt =~ "# SHOP-1: Checkout"
    assert prompt =~ "Status: open · Complexity: low"
    assert prompt =~ "Complexity: high · Depends on: SHOP-2"
    assert prompt =~ "### SHOP-3 (#3): UI"
    assert prompt =~ "run_subagents"
    assert prompt =~ "`close_issue` (repo `acme/shop`"
    assert prompt =~ "Run `mix test` before every push"
    assert prompt =~ "[SHOP-1][SUBTASK-KEY]"
    assert prompt =~ "`origin feature/SHOP-1`"
  end

  test "an issue without subtasks commits under its own key" do
    issue = %{
      "key" => "SHOP-4",
      "summary" => "Typo",
      "labels" => [],
      "description" => nil,
      "subtasks" => []
    }

    prompt = Prompt.render(issue, %{@repo | test_command: nil}, "bugfix/SHOP-4", "main")
    assert prompt =~ "`[SHOP-4] Typo`"
    refute prompt =~ "run_subagents"
    refute prompt =~ "before every push"
  end
end
