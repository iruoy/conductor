defmodule Conductor.PromptTest do
  use ExUnit.Case, async: true
  alias Conductor.Prompt

  @repo %Conductor.Config.Repository{
    name: "shop",
    owner: "acme",
    slug: "shop",
    test_command: "mix test"
  }
  @project %Conductor.Config.Project{
    repo: @repo,
    active_status: "In progress",
    done_status: "Done"
  }

  test "renders the issue, subtasks with complexity and dependencies, and the rules" do
    issue = %{
      "key" => "#1",
      "summary" => "Checkout",
      "type" => "Feature",
      "labels" => [],
      "description" => "Build checkout.",
      "subtasks" => [
        %{
          "key" => "#2",
          "summary" => "API",
          "status" => "Todo",
          "size" => "S",
          "priority" => "P1",
          "blocked_by" => [],
          "description" => ""
        },
        %{
          "key" => "#3",
          "summary" => "UI",
          "status" => "Todo",
          "size" => nil,
          "priority" => nil,
          "blocked_by" => ["#2"],
          "description" => "Pages"
        }
      ]
    }

    prompt = Prompt.render(issue, @project, "feature/1", "staging")
    assert prompt =~ "# #1: Checkout"
    assert prompt =~ "### #3: UI"
    assert prompt =~ "Status: Todo · Priority: P1 · Size: S · Complexity: low"
    assert prompt =~ "Size: none · Complexity: high · Depends on: #2"
    assert prompt =~ "run_subagents"
    assert prompt =~ "move it to In progress with `set_issue_status`"
    assert prompt =~ "move it to Done."
    assert prompt =~ "Run `mix test` before every push"
    assert prompt =~ "[#1][#SUBTASK-NUMBER]"
    assert prompt =~ "`origin feature/1`"
  end

  test "complexity follows the size" do
    sizes = %{
      "XS" => "low",
      "S" => "low",
      "M" => "medium",
      "L" => "high",
      "XL" => "high",
      nil => "high"
    }

    for {size, complexity} <- sizes,
        do: assert(Prompt.complexity(%{"size" => size}) == complexity)
  end

  test "an issue without subtasks commits under its own key" do
    issue = %{
      "key" => "#4",
      "summary" => "Typo",
      "labels" => [],
      "description" => nil,
      "subtasks" => []
    }

    prompt =
      Prompt.render(issue, %{@project | repo: %{@repo | test_command: nil}}, "bugfix/4", "main")

    assert prompt =~ "`[#4] Typo`"
    refute prompt =~ "run_subagents"
    refute prompt =~ "before every push"
  end
end
