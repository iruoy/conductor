defmodule Conductor.Repo.Migrations.Init do
  use Ecto.Migration

  def change do
    create table(:repos) do
      add :name, :string, null: false
      add :clone_url, :string, null: false
      add :owner, :string, null: false
      add :slug, :string, null: false
      add :base_branch, :string
      add :setup_script, :text
      add :test_command, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:repos, [:name])

    create table(:projects) do
      add :project_owner, :string, null: false
      add :project_number, :integer, null: false, default: 0
      add :runner_login, :string, null: false
      add :pickup_status, :string, null: false
      add :active_status, :string, null: false
      add :handoff_status, :string, null: false
      add :done_status, :string, null: false, default: "Done"
      add :item_filter, :string
      add :enabled, :boolean, null: false, default: true
      add :repo_id, references(:repos, on_delete: :restrict), null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:projects, [:repo_id, :project_owner, :project_number])

    create table(:settings) do
      add :models, :map, null: false, default: %{}
      add :max_concurrent, :integer, null: false, default: 3
      add :prune_days, :integer, null: false, default: 7
      timestamps(type: :utc_datetime)
    end

    create table(:runs, primary_key: false) do
      add :id, :string, primary_key: true
      add :issue_key, :string, null: false
      add :attempt, :integer, null: false
      add :project_id, references(:projects, on_delete: :restrict), null: false
      add :status, :string, null: false
      add :workspace_path, :string
      add :branch, :string
      add :issue_snapshot, :map
      add :outcome, :string
      add :summary, :text
      add :error, :text
      add :pr_url, :string
      timestamps(type: :utc_datetime)
    end

    create index(:runs, [:issue_key])
    create index(:runs, [:status])

    create table(:run_events) do
      add :run_id, references(:runs, type: :string, on_delete: :delete_all), null: false
      add :conversation, :integer, null: false
      add :role, :string, null: false
      add :entry, :string, null: false
      add :position, :integer
      add :kind, :string, null: false
      add :payload, :map, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:run_events, [:run_id, :conversation, :entry])

    create table(:questions) do
      add :run_id, references(:runs, type: :string, on_delete: :delete_all), null: false
      add :qid, :string, null: false
      add :text, :text, null: false
      add :answer, :text
      add :answered_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:questions, [:run_id, :qid])
  end
end
