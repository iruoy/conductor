defmodule Conductor.Runs.Run do
  @moduledoc """
  One attempt at one issue, with id `<issue key>-<attempt>` (`shop-12-1`).

  Status: `picked_up → provisioning → running ⇄ waiting_for_input → handing_off → completed | failed`.
  """
  use Ash.Resource,
    domain: Conductor.Runs,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine],
    notifiers: [Conductor.Runs.Notifier]

  @terminal ~w(completed failed)a

  postgres do
    table "runs"
    repo Conductor.Repo
  end

  state_machine do
    state_attribute :status
    initial_states [:picked_up]
    default_initial_state :picked_up

    transitions do
      transition :pump, from: :picked_up, to: :provisioning
      transition :provision_end, from: :provisioning, to: :running
      transition :wait_for_input, from: :running, to: :waiting_for_input
      transition :resume, from: :waiting_for_input, to: :running
      transition :settle, from: [:provisioning, :running, :waiting_for_input], to: :handing_off
      transition :complete, from: :handing_off, to: :completed
      transition :hand_off_failed, from: :handing_off, to: :failed

      transition :abort,
        from: [:picked_up, :provisioning, :running, :waiting_for_input],
        to: :failed

      transition :fail,
        from: [:picked_up, :provisioning, :running, :waiting_for_input, :handing_off],
        to: :failed
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:id, :issue_key, :attempt, :project_id, :issue_snapshot]
    end

    update :set_workspace_path do
      accept [:workspace_path]
    end

    update :set_branch do
      accept [:branch]
    end

    update :clear_workspace do
      accept []
      change set_attribute(:workspace_path, nil)
    end

    update :pump do
      accept []
      change transition_state(:provisioning)
    end

    update :provision_end do
      accept []
      change transition_state(:running)
    end

    update :wait_for_input do
      accept []
      change transition_state(:waiting_for_input)
    end

    update :resume do
      accept []
      change transition_state(:running)
    end

    update :settle do
      accept [:outcome, :summary, :error]
      change transition_state(:handing_off)
    end

    update :complete do
      accept [:pr_url]
      change transition_state(:completed)
    end

    update :hand_off_failed do
      accept [:error]
      change transition_state(:failed)
    end

    update :abort do
      accept []
      change set_attribute(:error, "aborted")
      change transition_state(:failed)
    end

    update :fail do
      accept [:error]
      change transition_state(:failed)
    end
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

  def statuses, do: AshStateMachine.Info.state_machine_all_states(__MODULE__)
  def terminal_statuses, do: @terminal
  def terminal?(%__MODULE__{status: status}), do: status in @terminal
  def id_for(issue_key, attempt), do: "#{issue_key}-#{attempt}"
end
