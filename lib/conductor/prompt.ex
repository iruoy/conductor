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
  ### <%= sub["key"] %> (#<%= sub["number"] %>): <%= sub["summary"] %>

  Status: <%= sub["status"] %> · Complexity: <%= complexity(sub) %><%= if sub["blocked_by"] != [] do %> · Depends on: <%= Enum.join(sub["blocked_by"], ", ") %><% end %>

  <%= blank_or(sub["description"], "(no description)") %>
  <% end %><% end %>
  ## How to work

  - You are in a git working tree of `<%= @repo.name %>` on branch `<%= @branch %>`, created from `origin/<%= @base %>`.
  <%= if @subtasks != [] do %>- Implement the subtasks with the `run_subagents` tool: one task per subtask that is not closed yet, with its key, title, complexity (<%= Enum.join(complexities(@subtasks), ", ") %> as listed above), complete instructions (a subagent sees nothing but its instructions), and `dependsOn` from the dependencies above. You may also implement small subtasks yourself.
  - Once the work of a subtask is committed, close its issue with `close_issue` (repo `<%= @repo.owner %>/<%= @repo.slug %>`, number as listed above).
  - Each subtask is committed separately with the message `[<%= @issue["key"] %>][SUBTASK-KEY] subtask title` (subagents commit only the files they changed; tell them so).
  <% else %>- Commit your work with the message `[<%= @issue["key"] %>] <%= @issue["summary"] %>`.
  <% end %><%= if @test_command do %>- Run `<%= @test_command %>` before every push and fix what fails.
  <% end %>- Push to `origin <%= @branch %>` (`git push -u origin HEAD`). Never push to any other branch and never force-push.
  - Do not open a pull request; Conductor does that after you finish.
  - When you need a decision only a human can make, use `ask_human` and stop.
  - Finish with a short summary and a final line `DONE`, or `FAILED: <reason>` when you could not complete the issue.
  """

  EEx.function_from_string(:defp, :render_template, @template, [:assigns])

  def render(issue, repo, branch, base) do
    render_template(%{
      issue: issue,
      subtasks: issue["subtasks"] || [],
      repo: repo,
      branch: branch,
      base: base,
      test_command: if(repo.test_command in [nil, ""], do: nil, else: repo.test_command)
    })
    |> String.replace(~r/\n{3,}/, "\n\n")
  end

  @doc "A subtask's complexity from its labels (`complexity:low`, `low`, ...); high when none."
  def complexity(subtask) do
    labels = Enum.map(subtask["labels"] || [], &String.downcase/1)

    Enum.find(~w(low medium high), "high", fn level ->
      level in labels or "complexity:#{level}" in labels or "complexity-#{level}" in labels
    end)
  end

  defp complexities(subtasks), do: subtasks |> Enum.map(&complexity/1) |> Enum.uniq()

  defp blank_or(value, default), do: if(value in [nil, ""], do: default, else: value)
end
