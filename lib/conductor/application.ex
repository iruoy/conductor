defmodule Conductor.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Conductor.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:conductor, :ecto_repos), skip: skip_migrations?()},
        {Phoenix.PubSub, name: Conductor.PubSub}
      ] ++ workers() ++ [ConductorWeb.Endpoint]

    Supervisor.start_link(children, strategy: :one_for_one, name: Conductor.Supervisor)
  end

  @doc """
  The runner and everything that talks to it, `rest_for_one`: when the runner exits, the Coordinator and Poller
  restart after it, and the Coordinator reconciles against the fresh runner.
  """
  def workers_spec do
    children = [
      Conductor.Runner,
      {Task.Supervisor, name: Conductor.Jobs},
      Conductor.Coordinator,
      Conductor.Poller
    ]

    %{
      id: Conductor.Workers,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [
           children,
           [strategy: :rest_for_one, max_restarts: 20, max_seconds: 60, name: Conductor.Workers]
         ]}
    }
  end

  defp workers do
    if Application.get_env(:conductor, :start_workers, true), do: [workers_spec()], else: []
  end

  # Releases migrate on start; in development `mix ecto.migrate` does.
  defp skip_migrations?, do: System.get_env("RELEASE_NAME") == nil
end
