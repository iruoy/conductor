defmodule Conductor.DataCase do
  @moduledoc "Tests against the database, each in its own sandboxed transaction (shared unless `async: true`)."

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Conductor.Repo

      import Ecto.Query
      import Conductor.DataCase
    end
  end

  setup tags do
    Conductor.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Conductor.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc "Groups native Ash errors by field for assertions."
  def errors_on(%Ash.Error.Invalid{errors: errors}) do
    errors
    |> Enum.flat_map(&List.wrap(AshPhoenix.FormData.Error.to_form_error(&1)))
    |> Enum.reduce(%{}, fn {field, message, opts}, result ->
      message =
        Regex.replace(~r"%{(\\w+)}", message, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)

      Map.update(result, field, [message], &(&1 ++ [message]))
    end)
  end
end
