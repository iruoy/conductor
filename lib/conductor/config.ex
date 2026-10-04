defmodule Conductor.Config do
  @moduledoc "Repositories, projects, and the global settings."
  import Ecto.Query
  alias Conductor.Config.{Project, Repository, Settings}
  alias Conductor.Repo

  ## Repositories

  def list_repos, do: Repo.all(from r in Repository, order_by: r.name)
  def get_repo!(id), do: Repo.get!(Repository, id)
  def change_repo(%Repository{} = repo, attrs \\ %{}), do: Repository.changeset(repo, attrs)
  def create_repo(attrs), do: %Repository{} |> Repository.changeset(attrs) |> Repo.insert()

  def update_repo(%Repository{} = repo, attrs),
    do: repo |> Repository.changeset(attrs) |> Repo.update()

  def delete_repo(%Repository{} = repo) do
    Repo.delete(repo)
  rescue
    Ecto.ConstraintError ->
      {:error, Ecto.Changeset.add_error(change_repo(repo), :name, "is used by a project")}
  end

  ## Projects

  def list_projects,
    do:
      Repo.all(
        from p in Project, order_by: [p.project_owner, p.project_number, p.id], preload: :repo
      )

  def list_enabled_projects, do: Repo.all(from p in Project, where: p.enabled, preload: :repo)
  def get_project!(id), do: Repo.get!(Project, id) |> Repo.preload(:repo)
  def change_project(%Project{} = project, attrs \\ %{}), do: Project.changeset(project, attrs)
  def create_project(attrs), do: %Project{} |> Project.changeset(attrs) |> Repo.insert()

  def update_project(%Project{} = project, attrs),
    do: project |> Project.changeset(attrs) |> Repo.update()

  def delete_project(%Project{} = project) do
    Repo.delete(project)
  rescue
    Ecto.ConstraintError ->
      {:error,
       Ecto.Changeset.add_error(
         change_project(project),
         :project_number,
         "has runs and cannot be deleted"
       )}
  end

  ## Settings

  def get_settings do
    Repo.one(from s in Settings, order_by: s.id, limit: 1) || Repo.insert!(%Settings{})
  end

  def change_settings(%Settings{} = settings, attrs \\ %{}),
    do: Settings.changeset(settings, attrs)

  def update_settings(%Settings{} = settings, attrs),
    do: settings |> Settings.changeset(attrs) |> Repo.update()

  @doc "The model map a run starts with: every complexity role falls back to the head model."
  def run_models(%Settings{models: models}) do
    head = models["head"]

    if head do
      for role <- Settings.roles(), into: %{}, do: {role, models[role] || head}
    end
  end
end
