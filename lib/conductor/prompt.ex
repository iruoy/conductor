defmodule Conductor.Prompt do
  @moduledoc "The first message of a run: the issue, its subtasks, and the rules of the job."
  require EEx

  @template """
  # <%= @issue["key"] %>: <%= @issue["summary"] %>

  Type: <%= @issue["type"] || "Issue" %><%= if @issue["labels"] != [] do %> · Labels: <%= Enum.join(@issue["labels"], ", ") %><% end %>

  <%= blank_or(@issue["description"], "(no description)") %>
  <%= if @subtasks != [] do %>
  ## Subtasks
  <%= for sub <- @subtasks do %>
  ### <%= sub["key"] %>: <%= sub["summary"] %>

  Status: <%= sub["status"] %><%= if sub["priority"] do %> · Priority: <%= sub["priority"] %><% end %> · Size: <%= sub["size"] || "none" %> · Complexity: <%= complexity(sub) %><%= if sub["blocked_by"] != [] do %> · Depends on: <%= Enum.join(sub["blocked_by"], ", ") %><% end %>

  <%= blank_or(sub["description"], "(no description)") %>
  <% end %><% end %>
  ## How to work

  - You are in a git working tree of `<%= @repo.name %>` on branch `<%= @branch %>`, created from `origin/<%= @base %>`.
  <%= if @subtasks != [] do %>- Implement the subtasks with the `run_subagents` tool: one task per subtask that is not <%= @project.done_status %> yet, with its key, title, complexity (<%= Enum.join(complexities(@subtasks), ", ") %> as listed above), complete instructions (a subagent sees nothing but its instructions), and `dependsOn` from the dependencies above. The subtasks are listed by priority: where the dependencies leave you a choice, do the higher priority first. You may also implement small subtasks yourself.
  - Before a subtask starts, move it to <%= @project.active_status %> with `set_issue_status`; once its work is committed, move it to <%= @project.done_status %>. Subagents have `set_issue_status` too, so you may leave this to them: tell them the issue number and both status names.
  - Each subtask is committed separately with the message `[<%= @issue["key"] %>][#SUBTASK-NUMBER] subtask title` (subagents commit only the files they changed; tell them so).
  <% else %>- Commit your work with the message `[<%= @issue["key"] %>] <%= @issue["summary"] %>`.
  <% end %><%= if @test_command do %>- Run `<%= @test_command %>` before every push and fix what fails.
  <% end %>- Push to `origin <%= @branch %>` (`git push -u origin HEAD`). Never push to any other branch and never force-push.
  - Do not open a pull request; Conductor does that after you finish.
  - When you need a decision only a human can make, use `ask_human` and stop.
  - Finish with a short summary and a final line `DONE`, or `FAILED: <reason>` when you could not complete the issue.
  """

  EEx.function_from_string(:defp, :render_template, @template, [:assigns])

  def render(issue, project, branch, base) do
    repo = project.repo

    render_template(%{
      project: project,
      issue: issue,
      subtasks: issue["subtasks"] || [],
      repo: repo,
      branch: branch,
      base: base,
      test_command: if(repo.test_command in [nil, ""], do: nil, else: repo.test_command)
    })
    |> String.replace(~r/\n{3,}/, "\n\n")
  end

  @doc """
  A subtask's complexity from its Size in the project: XS and S are low, M is medium, anything else (L, XL, or no
  size at all) is high.
  """
  def complexity(subtask) do
    case (subtask["size"] || "") |> String.downcase() |> String.replace(~r/[^a-z]/, "") do
      size when size in ~w(xs s tiny small low) -> "low"
      size when size in ~w(m medium) -> "medium"
      _ -> "high"
    end
  end

  defp complexities(subtasks), do: subtasks |> Enum.map(&complexity/1) |> Enum.uniq()

  defp blank_or(value, default), do: if(value in [nil, ""], do: default, else: value)
end
