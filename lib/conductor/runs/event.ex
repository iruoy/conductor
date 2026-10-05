defmodule Conductor.Runs.Event do
  @moduledoc """
  A persisted transcript item of one conversation of a run: a finished message (`entry` = `e:<entry id>`) or a
  started tool call (`t:<call id>`). Upserted, so replays after a runner restart are harmless.
  """
  use Ash.Resource,
    domain: Conductor.Runs,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "run_events"
    repo Conductor.Repo

    migration_types role: :string,
                    entry: :string,
                    kind: :string,
                    run_id: :string,
                    conversation: :integer,
                    position: :integer

    migration_defaults inserted_at: "nil"

    references do
      reference :run, on_delete: :delete
    end

    identity_index_names run_id_conversation_entry: "run_events_run_id_conversation_entry_index"
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:run_id, :conversation, :role, :entry, :position, :kind, :payload]
      upsert? true
      upsert_identity :run_id_conversation_entry
      upsert_fields [:payload, :kind, :position, :role]
    end
  end

  attributes do
    integer_primary_key :id
    attribute :conversation, :integer, allow_nil?: false, public?: true

    attribute :role, :string,
      allow_nil?: false,
      public?: true,
      constraints: [trim?: false, allow_empty?: true]

    attribute :entry, :string,
      allow_nil?: false,
      public?: true,
      constraints: [trim?: false, allow_empty?: true]

    attribute :position, :integer, public?: true

    attribute :kind, :string,
      allow_nil?: false,
      public?: true,
      constraints: [trim?: false, allow_empty?: true]

    attribute :payload, :map, allow_nil?: false, public?: true
    create_timestamp :inserted_at, type: :utc_datetime
  end

  relationships do
    belongs_to :run, Conductor.Runs.Run do
      attribute_type :string
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :run_id_conversation_entry, [:run_id, :conversation, :entry]
  end
end
