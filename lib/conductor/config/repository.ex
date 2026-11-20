defmodule Conductor.Config.Repository do
  @moduledoc "A repository runs work in: where to clone it from, its base branch, setup script and test command."
  use Ash.Resource, domain: Conductor.Config, data_layer: AshPostgres.DataLayer

  postgres do
    table "repos"
    repo Conductor.Repo

    foreign_key_names [{:name, "projects_repo_id_fkey", "is used by a project"}]
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  validations do
    validate match(:name, ~r/^[A-Za-z0-9._-]+$/),
      message: "letters, digits, dots, dashes and underscores only"
  end

  attributes do
    integer_primary_key :id

    attribute :name, :string do
      public? true
      allow_nil? false
    end

    attribute :clone_url, :string do
      public? true
      allow_nil? false
    end

    attribute :owner, :string do
      public? true
      allow_nil? false
    end

    attribute :slug, :string do
      public? true
      allow_nil? false
    end

    attribute :base_branch, :string do
      public? true
    end

    attribute :setup_script, :string do
      public? true
    end

    attribute :test_command, :string do
      public? true
    end
  end

  identities do
    identity :name, [:name], message: "has already been taken"
  end
end
