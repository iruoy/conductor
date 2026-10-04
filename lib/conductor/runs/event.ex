defmodule Conductor.Runs.Event do
  @moduledoc """
  A persisted transcript item of one conversation of a run: a finished message (`entry` = `e:<entry id>`) or a
  started tool call (`t:<call id>`). Upserted, so replays after a runner restart are harmless.
  """
  use Ecto.Schema

  schema "run_events" do
    field :run_id, :string
    field :conversation, :integer
    field :role, :string
    field :entry, :string
    field :position, :integer
    field :kind, :string
    field :payload, :map
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
