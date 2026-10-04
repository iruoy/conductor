defmodule Conductor.Config.Project do
  @moduledoc "A repository's GitHub issues that Conductor picks up when they are assigned to the runner account."
  use Ecto.Schema
  import Ecto.Changeset

  schema "projects" do
    field :key, :string
    field :runner_login, :string
    field :pickup_label, :string
    field :active_label, :string
    field :handoff_label, :string
    field :search_extra, :string
    field :enabled, :boolean, default: true
    belongs_to :repo, Conductor.Config.Repository
    timestamps(type: :utc_datetime)
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [
      :key,
      :runner_login,
      :pickup_label,
      :active_label,
      :handoff_label,
      :search_extra,
      :enabled,
      :repo_id
    ])
    |> validate_required([
      :key,
      :runner_login,
      :pickup_label,
      :active_label,
      :handoff_label,
      :repo_id
    ])
    |> update_change(:key, &String.upcase/1)
    |> validate_format(:key, ~r/^[A-Z][A-Z0-9_]*$/)
    |> unique_constraint(:key)
    |> foreign_key_constraint(:repo_id)
  end
end
