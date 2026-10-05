defmodule Conductor.Repo do
  use AshPostgres.Repo,
    otp_app: :conductor

  @impl true
  def installed_extensions, do: ["ash-functions"]

  # The lowest PostgreSQL version supported by this application.
  @impl true
  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}

  @impl true
  def prefer_transaction?, do: false
end
