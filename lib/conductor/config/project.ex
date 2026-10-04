defmodule Conductor.Config.Project do
  @moduledoc """
  A GitHub Project whose issues in one repository Conductor picks up when they are assigned to the runner account.
  The statuses are options of the project's Status field.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "projects" do
    field :project_owner, :string
    field :project_number, :integer
    field :runner_login, :string
    field :pickup_status, :string
    field :active_status, :string
    field :handoff_status, :string
    field :done_status, :string, default: "Done"
    field :item_filter, :string
    field :enabled, :boolean, default: true
    belongs_to :repo, Conductor.Config.Repository
    timestamps(type: :utc_datetime)
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [
      :project_owner,
      :project_number,
      :runner_login,
      :pickup_status,
      :active_status,
      :handoff_status,
      :done_status,
      :item_filter,
      :enabled,
      :repo_id
    ])
    |> validate_required([
      :project_owner,
      :project_number,
      :runner_login,
      :pickup_status,
      :active_status,
      :handoff_status,
      :done_status,
      :repo_id
    ])
    |> validate_number(:project_number, greater_than: 0)
    |> unique_constraint([:repo_id, :project_owner, :project_number],
      error_key: :project_number,
      message: "is already configured for this repository"
    )
    |> foreign_key_constraint(:repo_id)
  end
end
