defmodule Conductor.Config.Repository do
  @moduledoc "A git repository Conductor works in, hosted on GitHub."
  use Ecto.Schema
  import Ecto.Changeset

  schema "repos" do
    field :name, :string
    field :clone_url, :string
    field :owner, :string
    field :slug, :string
    field :base_branch, :string
    field :setup_script, :string
    field :test_command, :string
    timestamps(type: :utc_datetime)
  end

  def changeset(repository, attrs) do
    repository
    |> cast(attrs, [
      :name,
      :clone_url,
      :owner,
      :slug,
      :base_branch,
      :setup_script,
      :test_command
    ])
    |> validate_required([:name, :clone_url, :owner, :slug])
    |> validate_format(:name, ~r/^[A-Za-z0-9._-]+$/,
      message: "letters, digits, dots, dashes and underscores only"
    )
    |> unique_constraint(:name)
  end
end
