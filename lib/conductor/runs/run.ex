defmodule Conductor.Runs.Run do
  @moduledoc """
  One attempt at one issue, with id `<issue key>-<attempt>` (`shop-12-1`).

  Status: `picked_up → provisioning → running ⇄ waiting_for_input → handing_off → completed | failed`.
  """
  use Ash.Resource, domain: Conductor.Runs, data_layer: AshPostgres.DataLayer

  @statuses ~w(picked_up provisioning running waiting_for_input handing_off completed failed)
  @terminal ~w(completed failed)

  postgres do
    table "runs"
    repo Conductor.Repo
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:id, :issue_key, :attempt, :project_id, :status, :issue_snapshot]
    end

    update :update do
      primary? true

      accept [
        :status,
        :workspace_path,
        :branch,
        :issue_snapshot,
        :outcome,
        :summary,
        :error,
        :pr_url
      ]
    end
  end

  validations do
    validate one_of(:status, @statuses)
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :issue_key, :string do
      allow_nil? false
      public? true
    end

    attribute :attempt, :integer do
      allow_nil? false
      public? true
    end

    attribute :status, :string do
      allow_nil? false
      public? true
      default "picked_up"
    end

    attribute :issue_snapshot, :map, public?: true
    attribute :workspace_path, :string, public?: true, constraints: [trim?: false]
    attribute :branch, :string, public?: true, constraints: [trim?: false]
    attribute :outcome, :string, public?: true, constraints: [trim?: false]
    attribute :summary, :string, public?: true, constraints: [trim?: false]
    attribute :error, :string, public?: true, constraints: [trim?: false]
    attribute :pr_url, :string, public?: true, constraints: [trim?: false]
    create_timestamp :inserted_at, type: :utc_datetime
    update_timestamp :updated_at, type: :utc_datetime
  end

  relationships do
    belongs_to :project, Conductor.Config.Project do
      attribute_type :integer
      allow_nil? false
      public? true
    end

    has_many :questions, Conductor.Runs.Question do
      public? true
    end
  end

  def statuses, do: @statuses
  def terminal_statuses, do: @terminal
  def terminal?(%__MODULE__{status: status}), do: status in @terminal
  def id_for(issue_key, attempt), do: "#{issue_key}-#{attempt}"
end
