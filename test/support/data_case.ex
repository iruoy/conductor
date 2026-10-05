defmodule Conductor.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Conductor.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

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
