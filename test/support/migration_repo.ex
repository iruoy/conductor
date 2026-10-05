defmodule Conductor.MigrationRepo do
  @moduledoc false
  use Ecto.Repo, otp_app: :conductor, adapter: Ecto.Adapters.Postgres
end
