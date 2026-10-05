defmodule Conductor.Runs.Notifier do
  @moduledoc "Broadcasts persisted run and question changes after Ash commits their writes."
  use Ash.Notifier

  alias Conductor.Runs.{Question, Run}

  @pubsub Conductor.PubSub

  @impl true
  def load(Run, %{type: type}) when type in [:create, :update], do: [:project]
  def load(_, _), do: []

  @impl true
  def notify(%{data: %Run{} = run, action: %{type: type}})
      when type in [:create, :update] do
    Phoenix.PubSub.broadcast(@pubsub, "runs", {:run_updated, run})
    Phoenix.PubSub.broadcast(@pubsub, "run:" <> run.id, {:run_updated, run})
  end

  def notify(%{data: %Question{} = question, action: %{type: type}})
      when type in [:create, :update] do
    Phoenix.PubSub.broadcast(@pubsub, "run:" <> question.run_id, {:question, question})
  end

  def notify(_notification), do: :ok
end
