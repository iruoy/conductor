defmodule Conductor.Runs.Question do
  @moduledoc "A question the agent asked a human, and its answer once given."
  use Ecto.Schema

  schema "questions" do
    field :qid, :string
    field :text, :string
    field :answer, :string
    field :answered_at, :utc_datetime
    belongs_to :run, Conductor.Runs.Run, type: :string
    timestamps(type: :utc_datetime)
  end
end
