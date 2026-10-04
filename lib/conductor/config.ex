defmodule Conductor.Config do
  @moduledoc "Repositories, projects, and the global settings."
  use Ash.Domain
  alias Conductor.Config.{FormAdapter, Project, Repository, Settings}

  resources do
    resource Repository
    resource Project
    resource Settings
  end

  ## Repositories

  def list_repos, do: Repository |> Ash.Query.sort(:name) |> Ash.read!()
  def get_repo!(id), do: Ash.get!(Repository, id)

  def change_repo(%Repository{} = repo, attrs \\ %{}),
    do: repo |> changeset(attrs) |> FormAdapter.changeset()

  def create_repo(attrs), do: %Repository{} |> changeset(attrs) |> persist()
  def update_repo(%Repository{} = repo, attrs), do: repo |> changeset(attrs) |> persist()
  def delete_repo(%Repository{} = repo), do: destroy_record(repo)

  ## Projects

  def list_projects do
    Project
    |> Ash.Query.sort([:project_owner, :project_number, :id])
    |> Ash.Query.load(:repo)
    |> Ash.read!()
  end

  def list_enabled_projects, do: Project |> Ash.Query.for_read(:enabled) |> Ash.read!()
  def get_project!(id), do: Ash.get!(Project, id, load: [:repo])

  def change_project(%Project{} = project, attrs \\ %{}),
    do: project |> changeset(attrs) |> FormAdapter.changeset()

  def create_project(attrs), do: %Project{} |> changeset(attrs) |> persist()
  def update_project(%Project{} = project, attrs), do: project |> changeset(attrs) |> persist()
  def delete_project(%Project{} = project), do: destroy_record(project)

  ## Settings

  def get_settings, do: read_settings() || create_settings()

  defp read_settings do
    Settings |> Ash.Query.sort(:id) |> Ash.Query.limit(1) |> Ash.read_one!()
  end

  defp create_settings do
    # Serialize initialization without adding a singleton column or constraint
    # to the existing table. Recheck after locking in case another caller won.
    {:ok, settings} =
      Conductor.Repo.transaction(fn ->
        Conductor.Repo.query!("LOCK TABLE settings IN SHARE ROW EXCLUSIVE MODE")
        read_settings() || Ash.create!(Settings, %{})
      end)

    settings
  end

  def change_settings(%Settings{} = settings, attrs \\ %{}),
    do: settings |> changeset(attrs) |> FormAdapter.changeset()

  def update_settings(%Settings{} = settings, attrs),
    do: settings |> changeset(attrs) |> persist()

  @doc "The model map a run starts with: every complexity role falls back to the head model."
  def run_models(%Settings{models: models}) do
    head = models["head"]

    if head do
      for role <- Settings.roles(), into: %{}, do: {role, models[role] || head}
    end
  end

  defp changeset(%{id: nil} = record, attrs),
    do:
      record.__struct__
      |> Ash.Changeset.new()
      |> Map.put(:data, record)
      |> Ash.Changeset.for_create(:create, attrs, skip_unknown_inputs: [:*])

  defp changeset(record, attrs),
    do: Ash.Changeset.for_update(record, :update, attrs, skip_unknown_inputs: [:*])

  defp persist(changeset) do
    result =
      case changeset.action_type do
        :create -> Ash.create(changeset)
        :update -> Ash.update(changeset)
      end

    form_result(result, changeset)
  end

  defp destroy_record(record) do
    changeset = Ash.Changeset.for_destroy(record, :destroy)
    form_result(Ash.destroy(changeset, return_destroyed?: true), changeset)
  end

  defp form_result({:ok, record}, _changeset), do: {:ok, record}

  defp form_result({:error, error}, changeset),
    do: {:error, FormAdapter.changeset(changeset, Ash.Error.to_error_class(error).errors)}
end
