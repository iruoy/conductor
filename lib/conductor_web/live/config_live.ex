defmodule ConductorWeb.ConfigLive do
  use ConductorWeb, :live_view
  alias Conductor.{Config, Runner}
  alias Conductor.Config.{Project, Repository, Settings}

  @reasoning ~w(off minimal low medium high xhigh)

  @impl true
  def mount(_params, _session, socket) do
    settings = Config.get_settings()

    {:ok,
     socket
     |> assign(page_title: "Config", reasoning: @reasoning, models: [], models_error: nil)
     |> assign_settings(settings)
     |> assign(repo_form: nil, project_form: nil)
     |> load_lists()
     |> load_models()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Settings
        <:subtitle>
          Models per role and run limits. Subagents pick low, medium or high by subtask complexity.
        </:subtitle>
      </.header>

      <.form for={@settings_form} id="settings-form" phx-submit="save_settings" class="space-y-4">
        <p :if={@models_error} class="text-sm text-warning">
          Could not list models from the runner ({@models_error}); showing the saved choices only.
        </p>
        <div class="grid gap-x-6 gap-y-2 sm:grid-cols-2">
          <div :for={role <- Settings.roles()} class="flex items-end gap-2">
            <div class="grow">
              <.input
                type="select"
                id={"model-#{role}"}
                name={"settings[models][#{role}][model]"}
                label={"#{String.capitalize(role)} model"}
                value={model_value(@settings.models[role])}
                options={model_options(@models, @settings.models[role])}
                prompt={if role == "head", do: "Choose a model", else: "Same as head"}
              />
            </div>
            <div class="w-32">
              <.input
                type="select"
                id={"reasoning-#{role}"}
                name={"settings[models][#{role}][reasoning]"}
                label="Reasoning"
                value={(@settings.models[role] || %{})["reasoning"]}
                options={@reasoning}
                prompt="default"
              />
            </div>
          </div>
        </div>
        <div class="grid gap-x-6 sm:grid-cols-2">
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
        <.button variant="primary" phx-disable-with="Saving…">Save settings</.button>
      </.form>

      <div class="divider"></div>

      <.header>
        Repositories
        <:actions>
          <.button id="new-repo" phx-click="edit_repo" phx-value-id="new">New repository</.button>
        </:actions>
      </.header>

      <.form
        :if={@repo_form}
        for={@repo_form}
        id="repo-form"
        phx-submit="save_repo"
        class="rounded-box border border-base-300 p-4"
      >
        <div class="grid gap-x-6 sm:grid-cols-2">
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
          <.input field={@repo_form[:test_command]} label="Test command" placeholder="composer test" />
        </div>
        <.input field={@repo_form[:setup_script]} type="textarea" label="Setup script (bash)" />
        <div class="flex gap-2">
          <.button variant="primary" phx-disable-with="Saving…">Save repository</.button>
          <button type="button" phx-click="cancel_repo" class="btn btn-ghost">Cancel</button>
        </div>
      </.form>

      <.table id="repos" rows={@repos}>
        <:col :let={repo} label="Name"><span class="font-mono">{repo.name}</span></:col>
        <:col :let={repo} label="GitHub">{repo.owner}/{repo.slug}</:col>
        <:col :let={repo} label="Base">{repo.base_branch || "staging → main"}</:col>
        <:col :let={repo} label="Tests">
          <span class="font-mono text-xs">{repo.test_command}</span>
        </:col>
        <:action :let={repo}>
          <button
            id={"edit-repo-#{repo.id}"}
            phx-click="edit_repo"
            phx-value-id={repo.id}
            class="link"
          >Edit</button>
          <button
            id={"delete-repo-#{repo.id}"}
            phx-click="delete_repo"
            phx-value-id={repo.id}
            data-confirm={"Delete #{repo.name}?"}
            class="link text-error"
          >
            Delete
          </button>
        </:action>
      </.table>

      <div class="divider"></div>

      <.header>
        Projects
        <:actions>
          <.button
            id="new-project"
            phx-click="edit_project"
            phx-value-id="new"
            disabled={@repos == []}
          >
            New project
          </.button>
        </:actions>
      </.header>

      <.form
        :if={@project_form}
        for={@project_form}
        id="project-form"
        phx-submit="save_project"
        class="rounded-box border border-base-300 p-4"
      >
        <div class="grid gap-x-6 sm:grid-cols-2">
          <.input field={@project_form[:key]} label="Issue key prefix" placeholder="SHOP" />
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
            field={@project_form[:pickup_label]}
            label="Pick up issues labelled"
            placeholder="Ready for AI"
          />
          <.input
            field={@project_form[:active_label]}
            label="Label while working"
            placeholder="In Progress"
          />
          <.input
            field={@project_form[:handoff_label]}
            label="Label after the PR"
            placeholder="Review"
          />
        </div>
        <.input
          field={@project_form[:search_extra]}
          label="Extra search qualifiers"
          placeholder={~s(label:ai milestone:"v2")}
        />
        <.input field={@project_form[:enabled]} type="checkbox" label="Enabled" />
        <div class="flex gap-2">
          <.button variant="primary" phx-disable-with="Saving…">Save project</.button>
          <button type="button" phx-click="cancel_project" class="btn btn-ghost">Cancel</button>
        </div>
      </.form>

      <.table id="projects" rows={@projects}>
        <:col :let={project} label="Key"><span class="font-mono">{project.key}</span></:col>
        <:col :let={project} label="Repository">{project.repo.name}</:col>
        <:col :let={project} label="Flow">
          {project.pickup_label} → {project.active_label} → {project.handoff_label}
        </:col>
        <:col :let={project} label="Enabled">
          <.icon :if={project.enabled} name="hero-check" class="size-4 text-success" />
        </:col>
        <:action :let={project}>
          <button
            id={"edit-project-#{project.id}"}
            phx-click="edit_project"
            phx-value-id={project.id}
            class="link"
          >
            Edit
          </button>
          <button
            id={"delete-project-#{project.id}"}
            phx-click="delete_project"
            phx-value-id={project.id}
            data-confirm={"Delete #{project.key}?"}
            class="link text-error"
          >
            Delete
          </button>
        </:action>
      </.table>
    </Layouts.app>
    """
  end

  ## Settings

  @impl true
  def handle_event("save_settings", %{"settings" => params}, socket) do
    models =
      for {role, %{"model" => model} = choice} <- params["models"] || %{},
          model != "",
          into: %{} do
        [provider, model_id] = String.split(model, "/", parts: 2)

        {role,
         %{"provider" => provider, "modelId" => model_id, "reasoning" => choice["reasoning"]}}
      end

    attrs = Map.take(params, ["max_concurrent", "prune_days"]) |> Map.put("models", models)

    case Config.update_settings(socket.assigns.settings, attrs) do
      {:ok, settings} ->
        if Process.whereis(Conductor.Coordinator), do: Conductor.Coordinator.pump()
        {:noreply, socket |> assign_settings(settings) |> put_flash(:info, "Settings saved")}

      {:error, changeset} ->
        {:noreply, assign(socket, settings_form: to_form(changeset))}
    end
  end

  ## Repositories

  def handle_event("edit_repo", %{"id" => id}, socket) do
    repo = if id == "new", do: %Repository{}, else: Config.get_repo!(id)
    {:noreply, assign(socket, repo: repo, repo_form: to_form(Config.change_repo(repo)))}
  end

  def handle_event("cancel_repo", _params, socket), do: {:noreply, assign(socket, repo_form: nil)}

  def handle_event("save_repo", %{"repository" => params}, socket) do
    result =
      case socket.assigns.repo do
        %Repository{id: nil} -> Config.create_repo(params)
        repo -> Config.update_repo(repo, params)
      end

    case result do
      {:ok, repo} ->
        {:noreply,
         socket
         |> assign(repo_form: nil)
         |> load_lists()
         |> put_flash(:info, "Saved #{repo.name}")}

      {:error, changeset} ->
        {:noreply, assign(socket, repo_form: to_form(changeset))}
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
    project = if id == "new", do: %Project{}, else: Config.get_project!(id)

    {:noreply,
     assign(socket, project: project, project_form: to_form(Config.change_project(project)))}
  end

  def handle_event("cancel_project", _params, socket),
    do: {:noreply, assign(socket, project_form: nil)}

  def handle_event("save_project", %{"project" => params}, socket) do
    result =
      case socket.assigns.project do
        %Project{id: nil} -> Config.create_project(params)
        project -> Config.update_project(project, params)
      end

    case result do
      {:ok, project} ->
        {:noreply,
         socket
         |> assign(project_form: nil)
         |> load_lists()
         |> put_flash(:info, "Saved #{project.key}")}

      {:error, changeset} ->
        {:noreply, assign(socket, project_form: to_form(changeset))}
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
    assign(socket, settings: settings, settings_form: to_form(Config.change_settings(settings)))
  end

  defp load_lists(socket),
    do: assign(socket, repos: Config.list_repos(), projects: Config.list_projects())

  defp load_models(socket) do
    if connected?(socket) do
      case Runner.call(%{type: "models"}, 15_000) do
        {:ok, models} -> assign(socket, models: models, models_error: nil)
        {:error, reason} -> assign(socket, models_error: inspect(reason))
      end
    else
      socket
    end
  end

  defp model_value(nil), do: nil
  defp model_value(choice), do: "#{choice["provider"]}/#{choice["modelId"]}"

  defp model_options(models, current) do
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

    saved = model_value(current)
    listed? = Enum.any?(options, fn {_, opts} -> Enum.any?(opts, &(elem(&1, 1) == saved)) end)
    if saved && not listed?, do: [{"saved", [{saved, saved}]} | options], else: options
  end
end
