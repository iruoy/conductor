defmodule Conductor.Poller do
  @moduledoc """
  Polls GitHub every `interval` ms per enabled project for issues to pick up, and once a day prunes the workspaces of
  finished runs older than `prune_days`. `config :conductor, Conductor.Poller, interval: nil` disables the timers.
  """
  use GenServer
  require Logger
  alias Conductor.{Config, Coordinator, GitHub, Runs, Workspace}

  @day 24 * 60 * 60 * 1000
  @pubsub Conductor.PubSub
  @topic "poller"

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Polls now instead of at the next tick."
  def poll_now, do: GenServer.cast(__MODULE__, :poll_now)

  @doc "Subscribes the caller to `{:polled, last_poll}` messages, sent after every poll."
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  @doc """
  The configured `interval` (ms, `nil` when the timers are off) and the last poll: `nil` before the first one, else
  `%{at: DateTime, ok?: boolean, reason: String.t() | nil}`.
  """
  def status do
    if Process.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, :status),
      else: %{interval: nil, last_poll: nil}
  end

  @impl true
  def init(opts) do
    config = Keyword.merge(Application.get_env(:conductor, __MODULE__, []), opts)
    interval = Keyword.get(config, :interval, 60_000)

    if interval do
      Process.send_after(self(), :poll, 1_000)
      Process.send_after(self(), :prune, 60_000)
    end

    {:ok, %{interval: interval, last_poll: nil}}
  end

  @impl true
  def handle_call(:status, _from, state),
    do: {:reply, Map.take(state, [:interval, :last_poll]), state}

  @impl true
  def handle_cast(:poll_now, state) do
    poll()
    {:noreply, state}
  end

  def handle_cast({:polled, last_poll}, state) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:polled, last_poll})
    {:noreply, %{state | last_poll: last_poll}}
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

  @doc """
  Picks up every issue that is ready in a project and has no open run, highest priority first. The result (time and
  whether every project could be polled) is recorded for `status/0` and broadcast to `subscribe/0`.
  """
  def poll do
    reasons =
      for(project <- Config.list_enabled_projects(), reason = poll_safely(project), do: reason) ++
        sync_reviews()

    last_poll =
      %{at: DateTime.utc_now(:second), ok?: reasons == [], reason: Enum.join(reasons, "; ")}
      |> Map.update!(:reason, &if(&1 == "", do: nil, else: &1))

    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:polled, last_poll})
    :ok
  end

  defp sync_reviews do
    for run <- Runs.list_by_status([:completed]),
        not is_nil(run.pr_url),
        {:error, reason} <- [Coordinator.sync_review(run.id)] do
      "#{run.id} PR: #{reason_text(reason)}"
    end
  end

  defp poll_safely(project) do
    case poll_project(project) do
      :ok -> nil
      {:error, reason} -> "#{project.repo.name}: #{reason_text(reason)}"
    end
  rescue
    error ->
      Logger.error("poller: #{project.repo.name}: #{Exception.message(error)}")
      "#{project.repo.name}: #{Exception.message(error)}"
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)

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

        :ok

      {:error, reason} ->
        Logger.error("poller: #{project.repo.name} pickup failed: #{reason}")
        {:error, reason}
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
