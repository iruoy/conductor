defmodule ConductorWeb.ConfigLive do
  use ConductorWeb, :live_view
  alias Conductor.{Config, GitHub, Runner}
  alias Conductor.Config.{Project, Repository, Settings}
  alias AshPhoenix.Form

  @impl true
  def mount(_params, _session, socket) do
    settings = Config.get_settings()

    {:ok,
     socket
     |> assign(page_title: "Config", models: [], models_error: nil, model_defaults: %{})
     |> assign_settings(settings)
     |> assign(repo_form: nil, github_repos: nil, github_repos_error: nil)
     |> assign(project_form: nil, github_projects: nil, github_projects_error: nil)
     |> load_lists()
     |> load_models()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_page={:config} waiting_count={@waiting_count}>
      <div class="flex max-w-[1080px] flex-col gap-3 p-3">
        <section id="settings" class="rounded-lg border border-base-300 bg-base-100">
          <header class="flex h-11 items-center gap-3 border-b border-base-300 px-4">
            <h2 class="text-sm font-semibold">Settings</h2>
            <p class="min-w-0 flex-1 truncate text-fg-secondary">
              Models per task complexity and run limits
            </p>
            <button
              type="submit"
              form="settings-form"
              class="btn btn-sm btn-primary h-7 min-h-0"
              phx-disable-with="Saving…"
            >
              Save settings
            </button>
          </header>
          <.form
            for={@settings_form}
            id="settings-form"
            phx-change="change_settings"
            phx-submit="save_settings"
            class="space-y-3 p-4"
          >
            <div
              :if={@models_error}
              role="alert"
              class="flex items-center gap-2 rounded-md bg-chip-warning-bg px-3 py-1.5 text-chip-warning-fg"
            >
              <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
              <span>Could not list models from the runner (<span class="font-mono">{@models_error}</span>); showing the saved choices only.</span>
            </div>
            <div class="grid gap-x-3 gap-y-2 sm:grid-cols-2 xl:grid-cols-4">
              <div :for={{role, model_form} <- @model_forms} class="flex items-end gap-2">
                <div class="min-w-0 grow">
                  <.input
                    type="select"
                    id={"model-#{role}"}
                    field={model_form[:model]}
                    label={"#{String.capitalize(role)} model"}
                    options={model_options(@models, model_form[:model].value)}
                    prompt={if role == "head", do: "Choose a model", else: "Same as head"}
                  />
                </div>
                <div class="w-24 shrink-0">
                  <.input
                    type="select"
                    id={"reasoning-#{role}"}
                    field={model_form[:reasoning]}
                    label="Reasoning"
                    value={reasoning_value(@model_defaults, @model_choices[role])}
                    options={reasoning_options(@models, @model_choices[role])}
                    prompt={
                      if reasoning_value(@model_defaults, @model_choices[role]),
                        do: nil,
                        else: "default"
                    }
                  />
                </div>
              </div>
            </div>
            <div class="grid gap-x-3 sm:grid-cols-2 xl:grid-cols-4">
              <.input
                field={@settings_form[:max_concurrent]}
                type="number"
                label="Max concurrent runs (0 pauses)"
              />
              <.input
                field={@settings_form[:prune_days]}
                type="number"
                label="Prune workspaces after (days)"
              />
            </div>
          </.form>
        </section>

        <section id="repos-section" class="rounded-lg border border-base-300 bg-base-100">
          <header class="flex h-11 items-center gap-2 px-4">
            <h2 class="text-sm font-semibold">Repositories</h2>
            <span
              id="repos-count"
              class="rounded-full bg-muted px-1.5 text-[11px] leading-4 text-fg-secondary"
            >
              {length(@repos)}
            </span>
            <span class="flex-1"></span>
            <button
              id="new-repo"
              phx-click="edit_repo"
              phx-value-id="new"
              class="btn btn-sm h-[26px] min-h-0 border-line-strong bg-base-100 text-xs font-medium"
            >
              New repository
            </button>
          </header>

          <div class="overflow-x-auto border-t border-base-300">
            <.table id="repos" rows={@repos}>
              <:col :let={repo} label="Name"><span class="font-mono">{repo.name}</span></:col>
              <:col :let={repo} label="GitHub">{repo.owner}/{repo.slug}</:col>
              <:col :let={repo} label="Base">
                <span class="font-mono text-fg-secondary">{repo.base_branch || "staging → main"}</span>
              </:col>
              <:col :let={repo} label="Tests">
                <span class="font-mono">{repo.test_command}</span>
              </:col>
              <:action :let={repo}>
                <button
                  id={"edit-repo-#{repo.id}"}
                  phx-click="edit_repo"
                  phx-value-id={repo.id}
                  class="link link-hover"
                >
                  Edit
                </button>
                <button
                  id={"delete-repo-#{repo.id}"}
                  phx-click={show_modal("confirm-delete-repo-#{repo.id}")}
                  class="link link-hover text-error"
                >
                  Delete
                </button>
                <.confirm_modal
                  id={"confirm-delete-repo-#{repo.id}"}
                  title={"Delete #{repo.name}?"}
                  confirm="Delete"
                  on_confirm={JS.push("delete_repo", value: %{id: repo.id})}
                >
                  Conductor stops working in this repository. The repository on GitHub is not touched.
                </.confirm_modal>
              </:action>
            </.table>
          </div>

          <.form
            :if={@repo_form}
            for={@repo_form}
            id="repo-form"
            phx-change="change_repo"
            phx-submit="save_repo"
            class="space-y-2 border-t border-base-300 p-4"
          >
            <div
              :if={@github_repos_error}
              role="alert"
              class="flex items-center gap-2 rounded-md bg-chip-warning-bg px-3 py-1.5 text-chip-warning-fg"
            >
              <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
              <span>Could not list the repositories from GitHub ({@github_repos_error}); enter one by hand.</span>
            </div>
            <div :if={@github_repos}>
              <.input
                type="select"
                id="repo-github"
                name="repository[github]"
                label="GitHub repository (fills in the fields below)"
                value={@repo_form.params["github"]}
                options={Enum.map(@github_repos, & &1["full_name"])}
                prompt="Choose a repository"
              />
            </div>
            <div class="grid gap-x-3 gap-y-2 sm:grid-cols-2 xl:grid-cols-4">
              <.input field={@repo_form[:name]} label="Name" placeholder="shop-api" />
              <.input
                field={@repo_form[:clone_url]}
                label="Clone URL"
                placeholder="git@github.com:acme/shop-api.git"
              />
              <.input field={@repo_form[:owner]} label="GitHub owner" placeholder="acme" />
              <.input field={@repo_form[:slug]} label="Repository name" placeholder="shop-api" />
              <.input
                field={@repo_form[:base_branch]}
                label="Base branch"
                placeholder="staging, else main"
              />
              <.input
                field={@repo_form[:test_command]}
                label="Test command"
                placeholder="composer test"
              />
            </div>
            <.input
              field={@repo_form[:setup_script]}
              type="textarea"
              rows="3"
              label="Setup script (bash)"
            />
            <div class="flex justify-end gap-2">
              <button type="button" phx-click="cancel_repo" class="btn btn-sm h-7 min-h-0">
                Cancel
              </button>
              <button class="btn btn-sm btn-primary h-7 min-h-0" phx-disable-with="Saving…">
                Save repository
              </button>
            </div>
          </.form>
        </section>

        <section id="projects-section" class="rounded-lg border border-base-300 bg-base-100">
          <header class="flex h-11 items-center gap-2 px-4">
            <h2 class="text-sm font-semibold">Projects</h2>
            <span
              id="projects-count"
              class="rounded-full bg-muted px-1.5 text-[11px] leading-4 text-fg-secondary"
            >
              {length(@projects)}
            </span>
            <span class="flex-1"></span>
            <button
              id="new-project"
              phx-click="edit_project"
              phx-value-id="new"
              disabled={@repos == []}
              class="btn btn-sm h-[26px] min-h-0 border-line-strong bg-base-100 text-xs font-medium"
            >
              New project
            </button>
          </header>

          <div class="overflow-x-auto border-t border-base-300">
            <.table id="projects" rows={@projects}>
              <:col :let={project} label="GitHub project">
                <span class="font-mono">{project.project_owner}/{project.project_number}</span>
              </:col>
              <:col :let={project} label="Repository">
                <span class="font-mono">{project.repo.name}</span>
              </:col>
              <:col :let={project} label="Flow">
                <span class="flex items-center gap-1.5 whitespace-nowrap">
                  <span class="rounded bg-muted px-1.5 py-0.5">{project.pickup_status}</span>
                  <.icon name="hero-arrow-right-mini" class="size-3 text-fg-tertiary" />
                  <span class="rounded bg-chip-info-bg px-1.5 py-0.5 text-chip-info-fg">
                    {project.active_status}
                  </span>
                  <.icon name="hero-arrow-right-mini" class="size-3 text-fg-tertiary" />
                  <span class="rounded bg-chip-success-bg px-1.5 py-0.5 text-chip-success-fg">
                    {project.handoff_status}
                  </span>
                </span>
              </:col>
              <:col :let={project} label="Enabled">
                <span
                  role="img"
                  aria-label={if project.enabled, do: "Enabled", else: "Disabled"}
                  class={[
                    "flex h-4 w-7 items-center rounded-full p-0.5",
                    if(project.enabled, do: "justify-end bg-success", else: "justify-start bg-muted")
                  ]}
                >
                  <span class="size-3 rounded-full bg-white shadow-sm"></span>
                </span>
              </:col>
              <:action :let={project}>
                <button
                  id={"edit-project-#{project.id}"}
                  phx-click="edit_project"
                  phx-value-id={project.id}
                  class="link link-hover"
                >
                  Edit
                </button>
                <button
                  id={"delete-project-#{project.id}"}
                  phx-click={show_modal("confirm-delete-project-#{project.id}")}
                  class="link link-hover text-error"
                >
                  Delete
                </button>
                <.confirm_modal
                  id={"confirm-delete-project-#{project.id}"}
                  title={"Delete #{project.project_owner}/#{project.project_number}?"}
                  confirm="Delete"
                  on_confirm={JS.push("delete_project", value: %{id: project.id})}
                >
                  Conductor stops picking up its issues. The project on GitHub is not touched.
                </.confirm_modal>
              </:action>
            </.table>
          </div>

          <.form
            :if={@project_form}
            for={@project_form}
            id="project-form"
            phx-change="change_project"
            phx-submit="save_project"
            class="space-y-2 border-t border-base-300 p-4"
          >
            <div
              :if={@github_projects_error}
              role="alert"
              class="flex items-center gap-2 rounded-md bg-chip-warning-bg px-3 py-1.5 text-chip-warning-fg"
            >
              <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
              <span>Could not list the projects from GitHub ({@github_projects_error}); enter one by hand.</span>
            </div>
            <div :if={@github_projects}>
              <.input
                type="select"
                id="project-github"
                name="project[github]"
                label="GitHub project (fills in the fields below)"
                value={@project_pick}
                options={
                  Enum.map(
                    @github_projects,
                    &{"#{project_key(&1)} · #{&1["title"]}", project_key(&1)}
                  )
                }
                prompt="Choose a project"
              />
            </div>
            <div class="grid gap-x-3 gap-y-2 sm:grid-cols-2 xl:grid-cols-4">
              <.input
                field={@project_form[:repo_id]}
                type="select"
                label="Repository"
                options={Enum.map(@repos, &{&1.name, &1.id})}
              />
              <.input
                field={@project_form[:runner_login]}
                label="Runner GitHub login"
                placeholder="conductor-bot"
              />
              <.input
                field={@project_form[:project_owner]}
                label="GitHub project owner (organization or user)"
                placeholder="acme"
              />
              <.input
                field={@project_form[:project_number]}
                type="number"
                label="GitHub project number"
                placeholder="4"
              />
              <.status_input
                field={@project_form[:pickup_status]}
                label="Pick up from status"
                placeholder="Ready"
                statuses={@project_statuses}
              />
              <.status_input
                field={@project_form[:active_status]}
                label="Status while working"
                placeholder="In progress"
                statuses={@project_statuses}
              />
              <.status_input
                field={@project_form[:handoff_status]}
                label="Status after the PR"
                placeholder="In review"
                statuses={@project_statuses}
              />
              <.status_input
                field={@project_form[:done_status]}
                label="Status of finished subtasks"
                placeholder="Done"
                statuses={@project_statuses}
              />
            </div>
            <.input
              field={@project_form[:item_filter]}
              label="Project filter (optional, as in a project view)"
              placeholder="assignee:conductor-bot is:open"
            />
            <div class="flex items-center justify-between gap-2">
              <.input field={@project_form[:enabled]} type="checkbox" label="Enabled" />
              <div class="flex gap-2">
                <button type="button" phx-click="cancel_project" class="btn btn-sm h-7 min-h-0">
                  Cancel
                </button>
                <button class="btn btn-sm btn-primary h-7 min-h-0" phx-disable-with="Saving…">
                  Save project
                </button>
              </div>
            </div>
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :placeholder, :string, required: true
  attr :statuses, :list, default: nil

  # A status of the chosen GitHub project, or free text when its statuses are not known.
  defp status_input(%{statuses: nil} = assigns) do
    ~H"""
    <.input field={@field} label={@label} placeholder={@placeholder} />
    """
  end

  defp status_input(assigns) do
    ~H"""
    <.input
      field={@field}
      type="select"
      label={@label}
      options={Enum.uniq(@statuses ++ List.wrap(@field.value)) -- [""]}
      prompt="Choose a status"
    />
    """
  end

  ## Settings

  @impl true
  def handle_event("change_settings", %{"settings" => params} = event, socket) do
    choices = params["models"] || %{}

    # A newly chosen model starts at its own default reasoning level.
    choices =
      case event["_target"] do
        ["settings", "models", role, "model"] when is_map_key(choices, role) ->
          Map.update!(choices, role, &Map.put(&1, "reasoning", nil))

        _ ->
          choices
      end

    models = decode_models(choices)
    attrs = Map.put(params, "models", models)
    form = Form.validate(socket.assigns.settings_form, attrs)

    {:noreply,
     socket
     |> load_model_defaults(models)
     |> assign_settings_form(form, choices)}
  end

  def handle_event("save_settings", %{"settings" => params}, socket) do
    attrs = Map.put(params, "models", decode_models(params["models"] || %{}))

    case Form.submit(socket.assigns.settings_form, params: attrs) do
      {:ok, settings} ->
        if Process.whereis(Conductor.Coordinator), do: Conductor.Coordinator.pump()
        {:noreply, socket |> assign_settings(settings) |> put_flash(:info, "Settings saved")}

      {:error, form} ->
        {:noreply, assign_settings_form(socket, form, params["models"])}
    end
  end

  ## Repositories

  def handle_event("edit_repo", %{"id" => id}, socket) do
    repo = if id == "new", do: %Repository{}, else: Config.get_repo!(id)

    {:noreply,
     socket
     |> assign(repo: repo, repo_form: resource_form(repo, "repository"))
     |> load_github_repos()}
  end

  def handle_event("cancel_repo", _params, socket), do: {:noreply, assign(socket, repo_form: nil)}

  def handle_event("change_repo", %{"repository" => params} = event, socket) do
    params =
      if event["_target"] == ["repository", "github"],
        do: Map.merge(params, chosen_repo(socket.assigns.github_repos, params["github"])),
        else: params

    {:noreply,
     assign(socket, repo_form: socket.assigns.repo_form |> Form.validate(params) |> to_form())}
  end

  def handle_event("save_repo", %{"repository" => params}, socket) do
    case Form.submit(socket.assigns.repo_form, params: params) do
      {:ok, repo} ->
        {:noreply,
         socket
         |> assign(repo_form: nil)
         |> load_lists()
         |> put_flash(:info, "Saved #{repo.name}")}

      {:error, form} ->
        {:noreply, assign(socket, repo_form: to_form(form))}
    end
  end

  def handle_event("delete_repo", %{"id" => id}, socket) do
    case Config.delete_repo(Config.get_repo!(id)) do
      {:ok, _} -> {:noreply, load_lists(socket)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "This repository is used by a project")}
    end
  end

  ## Projects

  def handle_event("edit_project", %{"id" => id}, socket) do
    socket = load_github_projects(socket)

    project =
      if id == "new",
        do: %Project{runner_login: socket.assigns.github_login},
        else: Config.get_project!(id)

    {:noreply,
     socket |> assign(project: project) |> assign_project_form(resource_form(project, "project"))}
  end

  def handle_event("change_project", %{"project" => params} = event, socket) do
    params =
      if event["_target"] == ["project", "github"],
        do: Map.merge(params, chosen_project(socket.assigns.github_projects, params["github"])),
        else: params

    {:noreply, assign_project_form(socket, Form.validate(socket.assigns.project_form, params))}
  end

  def handle_event("cancel_project", _params, socket),
    do: {:noreply, assign(socket, project_form: nil)}

  def handle_event("save_project", %{"project" => params}, socket) do
    case Form.submit(socket.assigns.project_form, params: params) do
      {:ok, project} ->
        {:noreply,
         socket
         |> assign(project_form: nil)
         |> load_lists()
         |> put_flash(:info, "Saved #{project.project_owner}/#{project.project_number}")}

      {:error, form} ->
        {:noreply, assign_project_form(socket, form)}
    end
  end

  def handle_event("delete_project", %{"id" => id}, socket) do
    case Config.delete_project(Config.get_project!(id)) do
      {:ok, _} ->
        {:noreply, load_lists(socket)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "This project has runs and cannot be deleted")}
    end
  end

  ## Helpers

  defp assign_settings(socket, settings) do
    socket
    |> assign(settings: settings)
    |> assign_settings_form(Form.for_update(settings, :update, as: "settings"))
  end

  defp resource_form(%{id: nil} = record, name) do
    record.__struct__
    |> Form.for_create(:create, as: name, prepare_source: &Map.put(&1, :data, record))
    |> to_form()
  end

  defp resource_form(record, name),
    do: record |> Form.for_update(:update, as: name) |> to_form()

  # Models is a custom Ash map type rather than an embedded resource. Give each
  # typed role choice its own Phoenix form, deriving names from the parent field.
  # Only the select boundary uses provider/model; the action receives the typed map.
  defp assign_settings_form(socket, form, choices \\ nil) do
    form = to_form(form)
    models = Form.value(form, :models) || %{}

    model_forms =
      for role <- Settings.roles() do
        choice = models[role] || %{}

        params =
          (choices || %{})[role] ||
            %{
              "model" => model_value(choice),
              "reasoning" => choice["reasoning"]
            }

        {role, to_form(params, as: "#{form[:models].name}[#{role}]", id: "model-choice-#{role}")}
      end

    assign(socket,
      settings_form: form,
      model_forms: model_forms,
      model_choices: if(choices, do: decode_models(choices), else: models)
    )
  end

  defp decode_models(choices) do
    models =
      for {role, choice} <- choices, into: %{} do
        value = choice["model"] || ""

        model =
          case String.split(value, "/", parts: 2) do
            [provider, id] ->
              %{"provider" => provider, "modelId" => id, "reasoning" => choice["reasoning"]}

            _ ->
              %{}
          end

        {role, model}
      end

    {:ok, models} = Ash.Type.cast_input(Conductor.Config.Models, models)
    models
  end

  # The runner's entry for a model choice: its reasoning levels and default come from there.
  defp listed_model(_models, nil), do: nil

  defp listed_model(models, choice) do
    Enum.find(models, &(&1["provider"] == choice["provider"] and &1["id"] == choice["modelId"]))
  end

  # The level of a choice: the saved one, or else the model's default when the provider tells it.
  defp reasoning_value(_defaults, nil), do: nil

  defp reasoning_value(defaults, choice),
    do: choice["reasoning"] || defaults[model_value(choice)]

  # Asks the runner for the default level of every chosen model that has no level yet.
  defp load_model_defaults(socket, choices) do
    wanted =
      for {_role, choice} <- choices,
          choice["reasoning"] in [nil, ""],
          not is_map_key(socket.assigns.model_defaults, model_value(choice)),
          do: choice

    # Side by side, so the page waits for the slowest answer rather than for all of them in turn.
    defaults =
      wanted
      |> Enum.uniq_by(&model_value/1)
      |> Task.async_stream(
        fn choice ->
          command = %{
            type: "model_default",
            provider: choice["provider"],
            model_id: choice["modelId"]
          }

          case Runner.call(command, 15_000) do
            {:ok, level} -> {model_value(choice), level}
            {:error, _reason} -> {model_value(choice), nil}
          end
        end,
        timeout: :infinity
      )
      |> Enum.into(socket.assigns.model_defaults, fn {:ok, default} -> default end)

    assign(socket, model_defaults: defaults)
  end

  defp reasoning_options(models, choice) do
    levels = (listed_model(models, choice) || %{})["levels"] || []
    Enum.uniq(levels ++ List.wrap((choice || %{})["reasoning"])) -- [""]
  end

  defp load_lists(socket),
    do: assign(socket, repos: Config.list_repos(), projects: Config.list_projects())

  # A new repository is chosen from the token account's repositories; an existing one is edited by hand.
  defp load_github_repos(%{assigns: %{repo: %Repository{id: nil}}} = socket) do
    case GitHub.repositories() do
      {:ok, repos} -> assign(socket, github_repos: repos, github_repos_error: nil)
      {:error, reason} -> assign(socket, github_repos: nil, github_repos_error: reason)
    end
  end

  defp load_github_repos(socket), do: assign(socket, github_repos: nil, github_repos_error: nil)

  defp chosen_repo(github_repos, full_name) do
    github_repos
    |> Enum.find(%{}, &(&1["full_name"] == full_name))
    |> Map.take(["name", "owner", "slug", "clone_url"])
  end

  defp load_github_projects(socket) do
    case GitHub.projects() do
      {:ok, %{login: login, projects: projects}} ->
        assign(socket, github_projects: projects, github_login: login, github_projects_error: nil)

      {:error, reason} ->
        assign(socket, github_projects: nil, github_login: nil, github_projects_error: reason)
    end
  end

  # The form with the GitHub project it points at: the one selected in the list, and its statuses to choose from.
  defp assign_project_form(socket, form) do
    owner = Form.value(form, :project_owner)
    number = Form.value(form, :project_number)

    github_project =
      Enum.find(socket.assigns.github_projects || [], fn project ->
        project["project_number"] == number and is_binary(owner) and
          String.downcase(project["project_owner"]) == String.downcase(owner)
      end)

    assign(socket,
      project_form: to_form(form),
      project_pick: github_project && project_key(github_project),
      project_statuses: github_project && github_project["statuses"]
    )
  end

  defp project_key(github_project),
    do: "#{github_project["project_owner"]}/#{github_project["project_number"]}"

  # The chosen project with a guess at its statuses, as in GitHub's templates.
  defp chosen_project(github_projects, key) do
    case Enum.find(github_projects, &(project_key(&1) == key)) do
      nil ->
        %{}

      %{"statuses" => statuses} = github_project ->
        guesses = [
          {"pickup_status", [~r/ready/i, ~r/to.?do/i]},
          {"active_status", [~r/progress/i]},
          {"handoff_status", [~r/review/i]},
          {"done_status", [~r/done/i]}
        ]

        for {field, patterns} <- guesses,
            into: Map.take(github_project, ["project_owner", "project_number"]) do
          {field,
           Enum.find_value(patterns, "", fn pattern -> Enum.find(statuses, &(&1 =~ pattern)) end)}
        end
    end
  end

  defp load_models(socket) do
    if connected?(socket) do
      case Runner.call(%{type: "models"}, 15_000) do
        {:ok, models} ->
          socket
          |> assign(models: models, models_error: nil)
          |> load_model_defaults(socket.assigns.model_choices)

        {:error, reason} ->
          assign(socket, models_error: inspect(reason))
      end
    else
      socket
    end
  end

  defp model_value(%{"provider" => provider, "modelId" => id}), do: "#{provider}/#{id}"
  defp model_value(_), do: nil

  defp model_options(models, saved) do
    options =
      models
      |> Enum.group_by(& &1["provider"])
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {provider, models} ->
        {provider,
         models
         |> Enum.sort_by(& &1["id"])
         |> Enum.map(&{&1["name"] || &1["id"], "#{provider}/#{&1["id"]}"})}
      end)

    listed? = Enum.any?(options, fn {_, opts} -> Enum.any?(opts, &(elem(&1, 1) == saved)) end)

    if saved not in [nil, ""] and not listed?,
      do: [{"saved", [{saved, saved}]} | options],
      else: options
  end
end
