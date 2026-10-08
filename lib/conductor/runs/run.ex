defmodule Conductor.Runs.Run do
  @moduledoc """
  One attempt at one issue, with id `<issue key>-<attempt>` (`shop-12-1`).

  Status: `picked_up → provisioning → running ⇄ waiting_for_input → handing_off → completed | failed`.

  Every status the run gets is kept with its time in `Conductor.Runs.Run.Version` (table `runs_versions`), written
  by `AshPaperTrail` in the transaction of the action that sets it; read it with `Conductor.Runs.status_history/1`.
  """
  use Ash.Resource,
    domain: Conductor.Runs,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine, AshPaperTrail.Resource],
    notifiers: [Conductor.Runs.Notifier]

  @terminal ~w(completed failed)a

  postgres do
    table "runs"
    repo Conductor.Repo

    migration_types id: :string,
                    issue_key: :string,
                    workspace_path: :string,
                    branch: :string,
                    outcome: :string,
                    pr_url: :string,
                    status: :string,
                    attempt: :integer

    migration_defaults inserted_at: "nil", updated_at: "nil", status: "nil"

    references do
      reference :project, on_delete: :restrict
    end

    identity_index_names issue_key_attempt: "runs_issue_key_attempt_index"

    custom_indexes do
      index [:issue_key], name: "runs_issue_key_index"
      index [:status], name: "runs_status_index"
    end
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

  # A version is the status a run got and when, nothing else: the status is a column of its own, and every
  # attribute is left out of `changes`, so that the issue snapshot, summary and error are not copied on each
  # change. Only the create and the state transitions write one; an attribute added to the run goes in
  # `ignore_attributes` too.
  paper_trail do
    primary_key_type :uuid_v7
    change_tracking_mode :changes_only
    attributes_as_attributes [:status]
    store_action_name? true
    mixin Conductor.Runs.RunVersion

    ignore_attributes [
      :status,
      :issue_key,
      :attempt,
      :issue_snapshot,
      :workspace_path,
      :branch,
      :outcome,
      :summary,
      :error,
      :pr_url,
      :models,
      :project_id,
      :inserted_at,
      :updated_at
    ]

    on_actions [
      :pump,
      :provision_end,
      :wait_for_input,
      :resume,
      :settle,
      :complete,
      :hand_off_failed,
      :abort,
      :fail
    ]
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
      accept [:models]
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

    # The model choices the runner got in `start_run`, by role (`head`, `low`, `medium`, `high`), each
    # `%{"provider" => _, "modelId" => _, "reasoning" => _}`. A run from before they were kept has none.
    attribute :models, :map, public?: true
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

  identities do
    identity :issue_key_attempt, [:issue_key, :attempt]
  end

  def statuses, do: AshStateMachine.Info.state_machine_all_states(__MODULE__)
  def terminal_statuses, do: @terminal
  def terminal?(%__MODULE__{status: status}), do: status in @terminal
  def id_for(issue_key, attempt), do: "#{issue_key}-#{attempt}"
end
