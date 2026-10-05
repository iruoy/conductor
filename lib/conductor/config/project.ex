defmodule Conductor.Config.Project do
  @moduledoc "Project configuration stored in the existing projects table."
  use Ash.Resource, domain: Conductor.Config, data_layer: AshPostgres.DataLayer

  postgres do
    table "projects"
    repo Conductor.Repo

    migration_types project_owner: :string,
                    runner_login: :string,
                    pickup_status: :string,
                    active_status: :string,
                    handoff_status: :string,
                    done_status: :string,
                    item_filter: :string,
                    project_number: :integer

    migration_defaults inserted_at: "nil", updated_at: "nil"

    references do
      reference :repo, on_delete: :restrict
    end

    identity_index_names repo_id_project_owner_project_number:
                           "projects_repo_id_project_owner_project_number_index"

    foreign_key_names [
      {:project_number, "runs_project_id_fkey", "has runs and cannot be deleted"}
    ]
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    read :enabled do
      filter expr(enabled == true)
      prepare build(load: [:repo])
    end
  end

  validations do
    validate numericality(:project_number, greater_than: 0)
  end

  attributes do
    integer_primary_key :id

    attribute :project_owner, :string do
      public? true
      allow_nil? false
    end

    attribute :runner_login, :string do
      public? true
      allow_nil? false
    end

    attribute :pickup_status, :string do
      public? true
      allow_nil? false
    end

    attribute :active_status, :string do
      public? true
      allow_nil? false
    end

    attribute :handoff_status, :string do
      public? true
      allow_nil? false
    end

    attribute :done_status, :string do
      public? true
      allow_nil? false
      default "Done"
    end

    attribute :project_number, :integer do
      public? true
      allow_nil? false
      default 0
    end

    attribute :item_filter, :string do
      public? true
    end

    attribute :enabled, :boolean do
      public? true
      allow_nil? false
      default true
    end

    create_timestamp :inserted_at, type: :utc_datetime
    update_timestamp :updated_at, type: :utc_datetime
  end

  relationships do
    belongs_to :repo, Conductor.Config.Repository do
      attribute_type :integer
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :repo_id_project_owner_project_number, [:repo_id, :project_owner, :project_number] do
      field_names [:project_number]
      message "is already configured for this repository"
    end
  end
end
