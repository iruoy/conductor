defmodule Conductor.Config.Settings do
  @moduledoc """
  The single settings row. `models` maps each role (`head`, `low`, `medium`, `high`) to
  `%{"provider" => ..., "modelId" => ..., "reasoning" => ...}`; subagents pick a role by subtask complexity.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(head low medium high)

  schema "settings" do
    field :models, :map, default: %{}
    field :max_concurrent, :integer, default: 3
    field :prune_days, :integer, default: 7
    timestamps(type: :utc_datetime)
  end

  def roles, do: @roles

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:models, :max_concurrent, :prune_days])
    |> validate_required([:max_concurrent, :prune_days])
    |> validate_number(:max_concurrent, greater_than_or_equal_to: 0, less_than_or_equal_to: 20)
    |> validate_number(:prune_days, greater_than: 0)
    |> update_change(:models, &normalize_models/1)
  end

  defp normalize_models(models) do
    for {role, choice} <- models,
        role in @roles,
        is_map(choice),
        choice["modelId"] not in [nil, ""],
        into: %{} do
      {role,
       Map.take(choice, ["provider", "modelId", "reasoning"])
       |> Map.reject(fn {_, v} -> v in [nil, ""] end)}
    end
  end
end
