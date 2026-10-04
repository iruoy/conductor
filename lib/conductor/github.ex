defmodule Conductor.GitHub do
  @moduledoc """
  GitHub client with a bearer token: GraphQL for the issues of a GitHub Project, REST for branches and pull requests.

  A Conductor project points at a GitHub Project (`project_owner`, `project_number`) and reads three of its
  single-select fields per issue: `Status` (the workflow), `Size` (the complexity of a subtask) and `Priority` (the
  order in which issues are worked, by the order of the field's options). Subtasks are sub-issues in the same
  repository; "blocked by" relationships are the dependencies.

  Configure with `config :conductor, Conductor.GitHub, token: ...` (see runtime.exs) and optionally `base_url` and
  `req_options` (tests pass `plug: {Req.Test, Conductor.GitHub}`).
  """

  @item_fields """
  fragment itemFields on ProjectV2Item {
    id
    project { id }
    status: fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
    size: fieldValueByName(name: "Size") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
    priority: fieldValueByName(name: "Priority") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
  }
  """

  @issue_fields """
  fragment issueFields on Issue {
    number
    title
    body
    state
    url
    repository { nameWithOwner }
    issueType { name }
    labels(first: 50) { nodes { name } }
    assignees(first: 20) { nodes { login } }
    parent { state assignees(first: 20) { nodes { login } } }
    blockedBy(first: 50) { nodes { number state repository { nameWithOwner } } }
  }
  """

  @meta_query """
  query Meta($owner: String!, $number: Int!) {
    repositoryOwner(login: $owner) {
      ... on ProjectV2Owner {
        projectV2(number: $number) {
          id
          status: field(name: "Status") { ... on ProjectV2SingleSelectField { id options { id name } } }
          priority: field(name: "Priority") { ... on ProjectV2SingleSelectField { options { name } } }
        }
      }
    }
  }
  """

  @items_query """
  query Items($owner: String!, $number: Int!, $cursor: String, $filter: String) {
    repositoryOwner(login: $owner) {
      ... on ProjectV2Owner {
        projectV2(number: $number) {
          items(first: 100, after: $cursor, query: $filter) {
            pageInfo { hasNextPage endCursor }
            nodes { ...itemFields content { ... on Issue { ...issueFields } } }
          }
        }
      }
    }
  }
  #{@item_fields}
  #{@issue_fields}
  """

  @issue_query """
  query Issue($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) {
      issue(number: $number) {
        ...issueFields
        projectItems(first: 50) { nodes { ...itemFields } }
        subIssues(first: 100) {
          nodes { ...issueFields projectItems(first: 50) { nodes { ...itemFields } } }
        }
      }
    }
  }
  #{@item_fields}
  #{@issue_fields}
  """

  @item_query """
  query Item($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) {
      issue(number: $number) { projectItems(first: 50) { nodes { ...itemFields } } }
    }
  }
  #{@item_fields}
  """

  @set_status_mutation """
  mutation SetStatus($project: ID!, $item: ID!, $field: ID!, $option: String!) {
    updateProjectV2ItemFieldValue(
      input: {projectId: $project, itemId: $item, fieldId: $field, value: {singleSelectOptionId: $option}}
    ) {
      projectV2Item { id }
    }
  }
  """

  ## Issues

  @doc "The identifier of an issue's runs: `<repository name>-<issue number>`."
  def issue_key(project, number), do: "#{project.repo.name}-#{number}"

  @doc "The issue number in an issue key: `shop-12` is `12`."
  def number(key), do: key |> String.split("-") |> List.last() |> String.to_integer()

  @doc """
  The issues to pick up, highest priority first: open issues of the project's repository in the pickup status that
  are assigned to the runner. Issue relationships come before priority: an issue that is blocked by an open issue
  waits for it, and a sub-issue whose open parent is assigned to the runner is left to the parent's run.
  """
  def pickup(project) do
    with {:ok, meta} <- meta(project),
         {:ok, items} <- items(project, nil, []) do
      issues =
        for item <- items,
            issue = item["content"],
            is_map(issue) and is_integer(issue["number"]),
            pickup?(project, item, issue),
            do: snapshot(meta, issue, item)

      {:ok, Enum.sort_by(issues, &{&1["priority_rank"], &1["number"]})}
    end
  end

  defp pickup?(project, item, issue) do
    in_repo?(project.repo, issue) and open?(issue) and
      same?(get_in(item, ["status", "name"]), project.pickup_status) and
      assigned?(issue, project.runner_login) and
      not Enum.any?(nodes(issue["blockedBy"]), &open?/1) and
      not subtask_of_runner?(project, issue["parent"])
  end

  defp subtask_of_runner?(project, %{} = parent),
    do: open?(parent) and assigned?(parent, project.runner_login)

  defp subtask_of_runner?(_project, _parent), do: false

  defp open?(issue), do: issue["state"] == "OPEN"

  defp assigned?(issue, login),
    do: Enum.any?(nodes(issue["assignees"]), &same?(&1["login"], login))

  defp items(project, cursor, acc) do
    variables = Map.merge(project_variables(project), %{cursor: cursor, filter: filter(project)})

    with {:ok, data} <- graphql(@items_query, variables),
         {:ok, github_project} <- project_data(project, data) do
      page = github_project["items"]
      acc = acc ++ nodes(page)

      if page["pageInfo"]["hasNextPage"],
        do: items(project, page["pageInfo"]["endCursor"], acc),
        else: {:ok, acc}
    end
  end

  defp filter(project), do: if(blank?(project.item_filter), do: nil, else: project.item_filter)

  @doc """
  An issue with its subtasks, as the plain map stored in `runs.issue_snapshot`. The subtasks are the sub-issues in
  the same repository, highest priority first; `blocked_by` lists the keys (`#12`) of the issues one is blocked by.
  """
  def issue(project, number) do
    with {:ok, meta} <- meta(project),
         {:ok, data} <- graphql(@issue_query, repo_variables(project.repo, number)),
         %{} = issue <- get_in(data, ["repository", "issue"]) || not_found(project, number) do
      subtasks =
        for sub <- nodes(issue["subIssues"]), in_repo?(project.repo, sub) do
          snapshot(meta, sub, project_item(meta, sub))
        end

      {:ok,
       meta
       |> snapshot(issue, project_item(meta, issue))
       |> Map.put("subtasks", Enum.sort_by(subtasks, & &1["priority_rank"]))}
    end
  end

  @doc "Moves an issue to the option of the project's Status field named `status`. A no-op when it is already there."
  def transition(project, number, status) do
    with {:ok, meta} <- meta(project),
         {:ok, data} <- graphql(@item_query, repo_variables(project.repo, number)),
         %{} = issue <- get_in(data, ["repository", "issue"]) || not_found(project, number),
         %{} = item <- project_item(meta, issue) || {:error, "##{number} is not in the project"} do
      option = Enum.find(meta.statuses, &same?(&1["name"], status))

      cond do
        same?(get_in(item, ["status", "name"]), status) ->
          {:ok, :unchanged}

        option == nil ->
          {:error, "#{project_name(project)} has no status #{status}"}

        true ->
          variables = %{
            project: meta.id,
            item: item["id"],
            field: meta.status_field,
            option: option["id"]
          }

          with {:ok, _} <- graphql(@set_status_mutation, variables), do: {:ok, :transitioned}
      end
    end
  end

  @doc """
  What the runner's `set_issue_status` tool needs to move the issue of a run and its subtasks: the project and Status
  field ids, the status options, and the project item of each issue number.
  """
  def run_context(project, snapshot) do
    with {:ok, meta} <- meta(project) do
      items =
        for issue <- [snapshot | snapshot["subtasks"] || []],
            issue["item_id"],
            into: %{},
            do: {to_string(issue["number"]), issue["item_id"]}

      {:ok,
       %{
         repo: repo_name(project.repo),
         project_id: meta.id,
         status_field_id: meta.status_field,
         statuses: Map.new(meta.statuses, &{&1["name"], &1["id"]}),
         done_status: project.done_status,
         items: items
       }}
    end
  end

  defp meta(project) do
    with {:ok, data} <- graphql(@meta_query, project_variables(project)),
         {:ok, github_project} <- project_data(project, data) do
      case github_project["status"] do
        %{"id" => field, "options" => statuses} ->
          priorities =
            for option <- get_in(github_project, ["priority", "options"]) || [],
                do: option["name"]

          {:ok,
           %{
             id: github_project["id"],
             status_field: field,
             statuses: statuses,
             priorities: priorities
           }}

        _ ->
          {:error, "#{project_name(project)} has no single-select Status field"}
      end
    end
  end

  defp project_data(project, data) do
    case get_in(data, ["repositoryOwner", "projectV2"]) do
      %{} = github_project -> {:ok, github_project}
      _ -> {:error, "#{project_name(project)} was not found"}
    end
  end

  defp snapshot(meta, issue, item) do
    item = item || %{}
    priority = get_in(item, ["priority", "name"])
    repo = get_in(issue, ["repository", "nameWithOwner"])

    blocked_by =
      for blocker <- nodes(issue["blockedBy"]),
          same?(get_in(blocker, ["repository", "nameWithOwner"]), repo),
          do: "##{blocker["number"]}"

    %{
      "key" => "##{issue["number"]}",
      "number" => issue["number"],
      "summary" => issue["title"],
      "description" => issue["body"] || "",
      "url" => issue["url"],
      "type" => type(issue),
      "labels" => label_names(issue),
      "status" => get_in(item, ["status", "name"]) || String.downcase(issue["state"] || ""),
      "size" => get_in(item, ["size", "name"]),
      "priority" => priority,
      # The position of the priority among the field's options; issues without one come last.
      "priority_rank" =>
        Enum.find_index(meta.priorities, &same?(&1, priority)) || length(meta.priorities),
      "item_id" => item["id"],
      "blocked_by" => blocked_by
    }
  end

  # The issue type when the organization uses them, else Bug for an issue with a bug label.
  defp type(issue) do
    get_in(issue, ["issueType", "name"]) ||
      if Enum.any?(label_names(issue), &String.contains?(String.downcase(&1), "bug")), do: "Bug"
  end

  defp label_names(issue), do: for(label <- nodes(issue["labels"]), do: label["name"])

  defp project_item(meta, issue),
    do: Enum.find(nodes(issue["projectItems"]), &(get_in(&1, ["project", "id"]) == meta.id))

  # Sub-issues may live in other repositories, where the run has no working tree.
  defp in_repo?(repo, issue),
    do: same?(get_in(issue, ["repository", "nameWithOwner"]), repo_name(repo))

  defp nodes(%{"nodes" => nodes}) when is_list(nodes), do: Enum.reject(nodes, &is_nil/1)
  defp nodes(_), do: []

  defp not_found(project, number),
    do: {:error, "#{repo_name(project.repo)}##{number} was not found"}

  defp project_name(project),
    do: "GitHub project #{project.project_owner}/#{project.project_number}"

  defp project_variables(project),
    do: %{owner: project.project_owner, number: project.project_number}

  defp repo_variables(repo, number), do: %{owner: repo.owner, name: repo.slug, number: number}

  ## Repositories

  @doc """
  The repositories the token's account can reach that are not archived, by full name, as the attributes of a
  `Conductor.Config.Repository` (cloned over SSH) with their `full_name`.
  """
  def repositories, do: repositories(1, [])

  defp repositories(page, acc) do
    params = [per_page: 100, page: page, sort: "full_name"]

    with {:ok, repos} <- request(url: "/user/repos", params: params) do
      acc =
        acc ++
          for repo <- repos, not repo["archived"] do
            %{
              "full_name" => repo["full_name"],
              "name" => repo["name"],
              "owner" => repo["owner"]["login"],
              "slug" => repo["name"],
              "clone_url" => repo["ssh_url"]
            }
          end

      if length(repos) == 100, do: repositories(page + 1, acc), else: {:ok, acc}
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

  defp same?(a, b), do: is_binary(a) and is_binary(b) and String.downcase(a) == String.downcase(b)
  defp blank?(value), do: value in [nil, ""] or String.trim(value) == ""

  defp graphql(query, variables) do
    case request(method: :post, url: "/graphql", json: %{query: query, variables: variables}) do
      {:ok, %{"errors" => [_ | _] = errors}} ->
        {:error, "GitHub: #{Enum.map_join(errors, "; ", & &1["message"])}"}

      {:ok, %{"data" => data}} ->
        {:ok, data}

      {:ok, body} ->
        {:error, "GitHub: unexpected GraphQL response #{inspect(body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

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
