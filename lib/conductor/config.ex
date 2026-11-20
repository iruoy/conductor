defmodule Conductor.Config do
  @moduledoc "Repositories, projects, and the global settings."
  use Ash.Domain
  alias Conductor.Config.{Project, Repository, Settings}

  resources do
    resource Repository
    resource Project
    resource Settings
  end

  ## Repositories

  def list_repos, do: Repository |> Ash.Query.sort(:name) |> Ash.read!()
  def get_repo!(id), do: Ash.get!(Repository, id)
  def delete_repo(%Repository{} = repo), do: Ash.destroy(repo)

  ## Projects

  def list_projects do
    Project
    |> Ash.Query.sort([:project_owner, :project_number, :id])
    |> Ash.Query.load(:repo)
    |> Ash.read!()
  end

  def list_enabled_projects, do: Project |> Ash.Query.for_read(:enabled) |> Ash.read!()
  def get_project!(id), do: Ash.get!(Project, id, load: [:repo])
  def delete_project(%Project{} = project), do: Ash.destroy(project)

  ## Settings

  @doc "The one settings row, created with its defaults on first use."
  def get_settings, do: read_settings() || create_settings()

  defp read_settings do
    Settings |> Ash.Query.sort(:id) |> Ash.Query.limit(1) |> Ash.read_one!()
  end

  defp create_settings do
    # Two first callers must not both create a row: the second one finds the first one's after the lock.
    {:ok, settings} =
      Conductor.Repo.transaction(fn ->
        Conductor.Repo.query!("LOCK TABLE settings IN SHARE ROW EXCLUSIVE MODE")
        read_settings() || Ash.create!(Settings, %{})
      end)

    settings
  end

  @doc "The model map a run starts with: every complexity role falls back to the head model."
  def run_models(%Settings{models: models}) do
    head = models["head"]

    if head do
      for role <- Settings.roles(), into: %{}, do: {role, models[role] || head}
    end
  end
end
