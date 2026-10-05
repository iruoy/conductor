defmodule Conductor.Runs.Question do
  @moduledoc "A question the agent asked a human, and its answer once given."
  use Ash.Resource,
    domain: Conductor.Runs,
    data_layer: AshPostgres.DataLayer,
    notifiers: [Conductor.Runs.Notifier]

  postgres do
    table "questions"
    repo Conductor.Repo
    identity_index_names run_id_qid: "questions_run_id_qid_index"
  end

  actions do
    defaults [:read, update: [:answer, :answered_at]]

    create :create do
      primary? true
      accept [:run_id, :qid, :text]
      upsert? true
      upsert_identity :run_id_qid
      upsert_fields []
    end
  end

  attributes do
    integer_primary_key :id

    attribute :qid, :string,
      allow_nil?: false,
      public?: true,
      constraints: [trim?: false, allow_empty?: true]

    attribute :text, :string,
      allow_nil?: false,
      public?: true,
      constraints: [trim?: false, allow_empty?: true]

    attribute :answer, :string, public?: true, constraints: [trim?: false, allow_empty?: true]
    attribute :answered_at, :utc_datetime, public?: true
    create_timestamp :inserted_at, type: :utc_datetime
    update_timestamp :updated_at, type: :utc_datetime
  end

  relationships do
    belongs_to :run, Conductor.Runs.Run do
      attribute_type :string
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :run_id_qid, [:run_id, :qid]
  end
end
