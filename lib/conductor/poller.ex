defmodule Conductor.Poller do
  @moduledoc """
  Polls GitHub every `interval` ms per enabled project for issues to pick up, and once a day prunes the workspaces of
  finished runs older than `prune_days`. `config :conductor, Conductor.Poller, interval: nil` disables the timers.
  """
  use GenServer
  require Logger
  alias Conductor.{Config, Coordinator, GitHub, Runs, Workspace}

  @day 24 * 60 * 60 * 1000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Polls now instead of at the next tick."
  def poll_now, do: GenServer.cast(__MODULE__, :poll_now)

  @impl true
  def init(opts) do
    config = Keyword.merge(Application.get_env(:conductor, __MODULE__, []), opts)
    interval = Keyword.get(config, :interval, 60_000)

    if interval do
      Process.send_after(self(), :poll, 1_000)
      Process.send_after(self(), :prune, 60_000)
    end

    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_cast(:poll_now, state) do
    poll()
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    poll()
    Process.send_after(self(), :poll, state.interval)
    {:noreply, state}
  end

  def handle_info(:prune, state) do
    prune()
    Process.send_after(self(), :prune, @day)
    {:noreply, state}
  end

  @doc "Picks up every issue that is ready in a project and has no open run, highest priority first."
  def poll do
    for project <- Config.list_enabled_projects() do
      try do
        poll_project(project)
      rescue
        error -> Logger.error("poller: #{project.repo.name}: #{Exception.message(error)}")
      end
    end

    :ok
  end

  defp poll_project(project) do
    case GitHub.pickup(project) do
      {:ok, issues} ->
        keys = Map.new(issues, &{&1["number"], GitHub.issue_key(project, &1["number"])})
        open = MapSet.new(Runs.open_issue_keys(Map.values(keys)))

        for %{"number" => number} <- issues, key = keys[number], key not in open do
          with {:ok, snapshot} <- GitHub.issue(project, number),
               {:ok, run} <- Coordinator.enqueue(project, key, snapshot) do
            Logger.info("poller: picked up #{run.id}")
          else
            error -> Logger.warning("poller: could not pick up #{key}: #{inspect(error)}")
          end
        end

      {:error, reason} ->
        Logger.error("poller: #{project.repo.name} pickup failed: #{reason}")
    end
  end

  @doc "Removes the workspaces of finished runs older than the configured number of days."
  def prune do
    for run <- Runs.list_prunable(Config.get_settings().prune_days) do
      Workspace.remove(run.workspace_path)
      Runs.clear_workspace(run)
    end

    :ok
  end
end
