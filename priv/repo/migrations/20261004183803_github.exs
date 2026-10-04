defmodule Conductor.Repo.Migrations.Github do
  use Ecto.Migration

  def change do
    rename table(:repos), :bitbucket_workspace, to: :owner

    drop unique_index(:projects, [:jira_key])
    rename table(:projects), :jira_key, to: :key
    rename table(:projects), :runner_account_id, to: :runner_login
    rename table(:projects), :pickup_status, to: :pickup_label
    rename table(:projects), :active_status, to: :active_label
    rename table(:projects), :handoff_status, to: :handoff_label
    rename table(:projects), :jql_extra, to: :search_extra
    create unique_index(:projects, [:key])
  end
end
