defmodule Conductor.Config.FormAdapter do
  @moduledoc "Temporary Ecto form compatibility for ConfigLive until its AshPhoenix migration."

  # No persistence or validation lives here: Ash owns both. This only translates
  # cast attributes and errors for the existing Phoenix/Ecto form consumers.
  def changeset(%Ash.Changeset{} = source, errors \\ nil) do
    types =
      Map.new(source.resource.__schema__(:fields), fn field ->
        {field, source.resource.__schema__(:type, field)}
      end)

    changeset =
      Ecto.Changeset.change({source.data, types}, source.attributes)
      |> Map.put(:params, stringify_keys(source.params))
      |> Map.put(:action, source.action_type)

    errors = errors || source.errors

    Enum.reduce(errors, changeset, fn error, changeset ->
      error
      |> AshPhoenix.FormData.Error.to_form_error()
      |> List.wrap()
      |> Enum.reduce(changeset, fn {field, message, vars}, changeset ->
        Ecto.Changeset.add_error(changeset, field, message, vars)
      end)
    end)
  end

  defp stringify_keys(params), do: Map.new(params, fn {key, value} -> {to_string(key), value} end)
end
