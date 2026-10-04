defmodule Conductor.Config.Models do
  @moduledoc "Role model choices, persisted as the runner's string-keyed JSON map."
  use Ash.Type

  @impl true
  def storage_type(_), do: :map

  @impl true
  def cast_input(nil, _), do: {:ok, nil}

  def cast_input(models, _) when is_map(models) do
    normalized =
      for {role, choice} <- models,
          role in Conductor.Config.Settings.roles(),
          is_map(choice),
          choice["modelId"] not in [nil, ""],
          into: %{} do
        {role,
         Map.take(choice, ["provider", "modelId", "reasoning"])
         |> Map.reject(fn {_, value} -> value in [nil, ""] end)}
      end

    {:ok, normalized}
  end

  def cast_input(_, _), do: :error

  @impl true
  def cast_stored(value, _), do: {:ok, value}

  @impl true
  def dump_to_native(value, _), do: {:ok, value}
end
