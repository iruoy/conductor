defmodule Conductor.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        ConductorWeb.Telemetry,
        Conductor.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:conductor, :ecto_repos), skip: skip_migrations?()},
        {DNSCluster, query: Application.get_env(:conductor, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Conductor.PubSub}
      ] ++ workers() ++ [ConductorWeb.Endpoint]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Conductor.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ConductorWeb.Endpoint.config_change(changed, removed)
    :ok
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

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
