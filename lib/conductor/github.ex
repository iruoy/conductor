defmodule Conductor.GitHub do
  @moduledoc """
  GitHub REST client with a bearer token, for a project's issues and its repository's branches and pull requests.

  Issues are keyed `<project key>-<issue number>`: `SHOP-12` is `#12` in the repository of project `SHOP`. GitHub has
  no workflow statuses, so a project's pickup, active and hand-off statuses are labels, of which an issue carries one.
  Subtasks are sub-issues in the same repository.

  Configure with `config :conductor, Conductor.GitHub, token: ...` (see runtime.exs) and optionally `base_url` and
  `req_options` (tests pass `plug: {Req.Test, Conductor.GitHub}`).
  """

  ## Issues

  @doc "A project's issues matching the search `query`, as maps with `key`, `number`, `summary`, `status`, and `type`."
  def search(project, query) do
    with {:ok, %{"items" => items}} <-
           request(url: "/search/issues", params: [q: query, per_page: 100]) do
      {:ok, Enum.map(items, &summary(project, &1))}
    end
  end

  @doc "The search query that picks up a project's issues."
  def pickup_query(project) do
    query =
      Enum.join(
        [
          "repo:#{repo_name(project.repo)}",
          "is:issue",
          "is:open",
          "assignee:#{project.runner_login}",
          ~s(label:"#{project.pickup_label}")
        ],
        " "
      )

    if blank?(project.search_extra), do: query, else: "#{query} #{project.search_extra}"
  end

  @doc """
  An issue with its subtasks, as the plain map stored in `runs.issue_snapshot`. `blocked_by` lists the keys of the
  issues a subtask is blocked by.
  """
  def issue(project, key) do
    path = issue_path(project.repo, key)

    with {:ok, issue} <- request(url: path),
         {:ok, sub_issues} <- request(url: "#{path}/sub_issues", params: [per_page: 100]) do
      subtasks =
        for sub <- sub_issues, same_repo?(project.repo, sub) do
          project |> snapshot(sub) |> Map.put("blocked_by", blocked_by(project, sub))
        end

      {:ok, project |> snapshot(issue) |> Map.put("subtasks", subtasks)}
    end
  end

  @doc """
  Gives an issue the status label `label`, taking the project's other status labels off it. A no-op when it is
  already there.
  """
  def transition(project, key, label) do
    path = issue_path(project.repo, key)

    with {:ok, issue} <- request(url: path) do
      current = label_names(issue)
      statuses = [project.pickup_label, project.active_label, project.handoff_label]

      stale =
        for name <- current,
            Enum.any?(statuses, &same?(&1, name)),
            not same?(name, label),
            do: name

      present? = Enum.any?(current, &same?(&1, label))

      if present? and stale == [] do
        {:ok, :unchanged}
      else
        with :ok <- remove_labels(path, stale),
             {:ok, _} <- if(present?, do: {:ok, nil}, else: add_label(path, label)) do
          {:ok, :transitioned}
        end
      end
    end
  end

  @doc "The issue number in a key: `SHOP-12` is `12`."
  def number(key), do: key |> String.split("-") |> List.last() |> String.to_integer()

  defp remove_labels(path, labels) do
    Enum.reduce_while(labels, :ok, fn label, :ok ->
      case request(method: :delete, url: "#{path}/labels/#{encode(label)}") do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp add_label(path, label),
    do: request(method: :post, url: "#{path}/labels", json: %{labels: [label]})

  defp blocked_by(project, issue) do
    path = "#{repo_path(project.repo)}/issues/#{issue["number"]}/dependencies/blocked_by"

    case request(url: path, params: [per_page: 100]) do
      {:ok, blockers} when is_list(blockers) ->
        for blocker <- blockers, same_repo?(project.repo, blocker), do: key(project, blocker)

      _ ->
        []
    end
  end

  defp summary(project, issue) do
    %{
      "key" => key(project, issue),
      "number" => issue["number"],
      "summary" => issue["title"],
      "status" => issue["state"],
      "type" => type(issue),
      "url" => issue["html_url"]
    }
  end

  defp snapshot(project, issue) do
    project
    |> summary(issue)
    |> Map.merge(%{
      "description" => issue["body"] || "",
      "labels" => label_names(issue),
      "blocked_by" => []
    })
  end

  # The issue type when the organization uses them, else Bug for an issue with a bug label.
  defp type(issue) do
    get_in(issue, ["type", "name"]) ||
      if Enum.any?(label_names(issue), &String.contains?(String.downcase(&1), "bug")), do: "Bug"
  end

  defp label_names(issue) do
    for label <- List.wrap(issue["labels"]), do: if(is_map(label), do: label["name"], else: label)
  end

  defp key(project, issue), do: "#{project.key}-#{issue["number"]}"

  defp issue_path(repo, key), do: "#{repo_path(repo)}/issues/#{number(key)}"

  # Sub-issues and blockers may live in other repositories, whose numbers mean nothing in this one.
  defp same_repo?(repo, issue) do
    case issue["repository_url"] do
      nil -> true
      url -> url |> String.downcase() |> String.ends_with?(String.downcase(repo_path(repo)))
    end
  end

  ## Branches and pull requests

  def branch_exists?(repo, branch) do
    case response(url: "#{repo_path(repo)}/branches/#{URI.encode(branch)}") do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> {:ok, true}
      {:ok, %Req.Response{status: 404}} -> {:ok, false}
      {:ok, %Req.Response{status: status, body: body}} -> http_error(status, body)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the web URL of the open PR from `branch`, creating it into `base` when there is none."
  def find_or_create_pr(repo, branch, base, title, description \\ "") do
    params = [head: "#{repo.owner}:#{branch}", state: "open"]

    with {:ok, existing} <- request(url: "#{repo_path(repo)}/pulls", params: params) do
      case existing do
        [pr | _] ->
          {:ok, pr["html_url"]}

        [] ->
          body = %{title: title, body: description, head: branch, base: base}

          with {:ok, pr} <- request(method: :post, url: "#{repo_path(repo)}/pulls", json: body) do
            {:ok, pr["html_url"]}
          end
      end
    end
  end

  ## HTTP

  defp repo_name(repo), do: "#{repo.owner}/#{repo.slug}"
  defp repo_path(repo), do: "/repos/#{repo_name(repo)}"

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  defp same?(a, b), do: is_binary(a) and is_binary(b) and String.downcase(a) == String.downcase(b)
  defp blank?(value), do: value in [nil, ""] or String.trim(value) == ""

  defp request(options) do
    case response(options) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> http_error(status, body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp http_error(status, body), do: {:error, "GitHub HTTP #{status}: #{inspect(body)}"}

  defp response(options) do
    config = Application.get_env(:conductor, __MODULE__, [])

    if blank?(config[:token]),
      do: {:error, "GitHub is not configured (set GITHUB_TOKEN)"},
      else: do_request(config, options)
  end

  defp do_request(config, options) do
    [
      base_url: config[:base_url] || "https://api.github.com",
      auth: {:bearer, config[:token]},
      headers: [accept: "application/vnd.github+json", x_github_api_version: "2022-11-28"],
      retry: :transient,
      max_retries: 2
    ]
    |> Keyword.merge(config[:req_options] || [])
    |> Keyword.merge(options)
    |> Req.request()
    |> case do
      {:ok, response} -> {:ok, response}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end
end
