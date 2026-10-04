defmodule Conductor.Repo.Migrations.Github do
  use Ecto.Migration

  # From Jira and Bitbucket to GitHub: a project is a GitHub Project (owner and number) instead of a Jira key.
  # Projects that were configured for Jira keep their row with number 0 and have to be edited.
  def change do
    rename table(:repos), :bitbucket_workspace, to: :owner

    drop unique_index(:projects, [:jira_key])
    rename table(:projects), :jira_key, to: :project_owner
    rename table(:projects), :runner_account_id, to: :runner_login
    rename table(:projects), :jql_extra, to: :item_filter

    alter table(:projects) do
      add :project_number, :integer, null: false, default: 0
      add :done_status, :string, null: false, default: "Done"
    end

    create unique_index(:projects, [:repo_id, :project_owner, :project_number])
  end
end
