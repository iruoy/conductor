defmodule Conductor.Coordinator do
  @moduledoc """
  Moves runs through their lifecycle and keeps at most `max_concurrent` of them busy.

  The database is the queue: `picked_up` runs wait for a slot, and `provisioning`, `running` and `handing_off` runs
  hold one (a run waiting for a human does not). Provisioning and hand-off run as tasks under `Conductor.Jobs`; both
  are idempotent, so on start the Coordinator reconciles the database with the runner (`sync`) and simply re-runs
  whatever was interrupted.
  """
  use GenServer
  require Logger
  alias Conductor.{Config, GitHub, Prompt, Runner, Runs, Workspace}
  alias Conductor.Runs.Run

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Queues a new run for an issue, unless one is already open."
  def enqueue(project, issue_key, snapshot),
    do: GenServer.call(__MODULE__, {:enqueue, project, issue_key, snapshot})

  @doc "Queues the next attempt of a finished run's issue, with a fresh issue snapshot when GitHub answers."
  def retry(run_id) do
    run = Runs.get_run!(run_id)

    snapshot =
      case GitHub.issue(run.project, run.issue_key) do
        {:ok, snapshot} -> snapshot
        {:error, _} -> run.issue_snapshot
      end

    GenServer.call(__MODULE__, {:retry, run_id, snapshot})
  end

  def abort(run_id), do: GenServer.call(__MODULE__, {:abort, run_id}, 30_000)

  def answer(run_id, qid, text) do
    with %{answered_at: nil} = question <-
           Runs.get_question(run_id, qid) || {:error, :unknown_question},
         {:ok, _} <- Runner.call(%{type: "answer", run_id: run_id, qid: qid, text: text}) do
      Runs.answer_question(question, text)
    else
      %{answered_at: _} -> {:error, :already_answered}
      error -> error
    end
  end

  def pump, do: GenServer.cast(__MODULE__, :pump)

  ## Server

  @impl true
  def init(_opts), do: {:ok, %{jobs: %{}}, {:continue, :reconcile}}

  @impl true
  def handle_continue(:reconcile, state) do
    known =
      case Runner.call(%{type: "sync"}) do
        {:ok, %{"runs" => runs}} ->
          Map.new(runs, &{&1["run_id"], &1})

        error ->
          Logger.error("coordinator: runner sync failed: #{inspect(error)}")
          %{}
      end

    state =
      Enum.reduce(
        Runs.list_by_status(~w(provisioning running waiting_for_input handing_off)),
        state,
        fn run, state ->
          reconcile(run, known[run.id], state)
        end
      )

    {:noreply, pump(state)}
  end

  @impl true
  def handle_call({:enqueue, project, issue_key, snapshot}, _from, state) do
    if Runs.open_issue_keys([issue_key]) == [] do
      result = Runs.create_run(project, issue_key, snapshot)
      {:reply, result, pump(state)}
    else
      {:reply, {:error, :already_open}, state}
    end
  end

  def handle_call({:retry, run_id, snapshot}, _from, state) do
    run = Runs.get_run!(run_id)

    cond do
      not Run.terminal?(run) -> {:reply, {:error, :still_open}, state}
      Runs.open_issue_keys([run.issue_key]) != [] -> {:reply, {:error, :already_open}, state}
      true -> {:reply, Runs.create_run(run.project, run.issue_key, snapshot), pump(state)}
    end
  end

  def handle_call({:abort, run_id}, _from, state) do
    run = Runs.get_run!(run_id)

    result =
      case run.status do
        status when status in ~w(picked_up provisioning) ->
          Runs.update_run(run, %{status: "failed", error: "aborted"})

        status when status in ~w(running waiting_for_input) ->
          # The runner settles the run as failed; the hand-off then marks it so.
          with {:error, reason} <- Runner.call(%{type: "abort", run_id: run_id}) do
            Logger.warning("coordinator: runner abort of #{run_id} failed: #{inspect(reason)}")
            Runs.update_run(run, %{status: "failed", error: "aborted"})
          end

        _ ->
          {:error, :not_abortable}
      end

    {:reply, result, pump(state)}
  end

  @impl true
  def handle_cast(:pump, state), do: {:noreply, pump(state)}

  @impl true
  def handle_info({:runner, %{"type" => "run_settled", "run_id" => run_id} = settled}, state) do
    case Runs.get_run(run_id) do
      %Run{status: status} = run when status in ~w(provisioning running waiting_for_input) ->
        {:noreply, run |> settle(settled) |> start_handoff(state)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:runner, _event}, state), do: {:noreply, state}

  def handle_info({ref, result}, %{jobs: jobs} = state) when is_map_key(jobs, ref) do
    Process.demonitor(ref, [:flush])
    {{kind, run_id}, jobs} = Map.pop(jobs, ref)

    case result do
      :ok -> :ok
      {:error, reason} -> fail(run_id, kind, reason)
      other -> fail(run_id, kind, other)
    end

    {:noreply, pump(%{state | jobs: jobs})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{jobs: jobs} = state)
      when is_map_key(jobs, ref) do
    {{kind, run_id}, jobs} = Map.pop(jobs, ref)
    fail(run_id, kind, Exception.format_exit(reason))
    {:noreply, pump(%{state | jobs: jobs})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  ## Lifecycle

  defp reconcile(%Run{status: "provisioning"} = run, _known, state),
    do: start_provision(run, state)

  defp reconcile(%Run{status: "handing_off"} = run, _known, state), do: start_handoff(run, state)

  # Running or waiting, but the runner never got (or lost) the run: provision again, which re-sends start_run.
  defp reconcile(run, nil, state), do: start_provision(run, state)

  defp reconcile(run, %{"status" => "settled", "settled" => settled}, state) do
    run |> settle(settled) |> start_handoff(state)
  end

  defp reconcile(run, %{"status" => status} = known, state) do
    Runs.sync_questions(run.id, known["questions"] || [])
    if run.status != status, do: Runs.update_run(run, %{status: status})
    state
  end

  defp settle(run, settled) do
    {:ok, run} =
      Runs.update_run(run, %{
        status: "handing_off",
        outcome: settled["outcome"],
        summary: settled["summary"],
        error: settled["error"]
      })

    run
  end

  defp pump(state) do
    settings = Config.get_settings()

    if Runs.active_count() < settings.max_concurrent do
      case Runs.next_queued() do
        nil ->
          state

        run ->
          {:ok, run} = Runs.update_run(run, %{status: "provisioning"})
          pump(start_provision(run, state))
      end
    else
      state
    end
  end

  defp start_provision(run, state),
    do: start_job(state, {:provision, run.id}, fn -> provision(run.id) end)

  defp start_handoff(run, state),
    do: start_job(state, {:handoff, run.id}, fn -> hand_off(run.id) end)

  defp start_job(state, key, fun) do
    if key in Map.values(state.jobs) do
      state
    else
      task = Task.Supervisor.async_nolink(Conductor.Jobs, fun)
      put_in(state.jobs[task.ref], key)
    end
  end

  defp fail(run_id, kind, reason) do
    message = if is_binary(reason), do: reason, else: inspect(reason)
    Logger.error("coordinator: #{kind} of #{run_id} failed: #{message}")

    case Runs.get_run(run_id) do
      %Run{} = run ->
        unless Run.terminal?(run), do: Runs.update_run(run, %{status: "failed", error: message})

      nil ->
        :ok
    end
  end

  ## Jobs

  @doc false
  def provision(run_id) do
    run = Runs.get_run!(run_id)
    project = run.project
    repo = project.repo

    with {:ok, _} <- GitHub.transition(project, run.issue_key, project.active_label),
         {:ok, ws} <- Workspace.provision(repo, run.issue_key, run.issue_snapshot),
         {:ok, run} <- Runs.update_run(run, %{workspace_path: ws.path, branch: ws.branch}),
         :ok <- record_setup(run, ws.setup_output),
         models when is_map(models) <-
           Config.run_models(Config.get_settings()) || {:error, "no head model configured"},
         prompt = Prompt.render(run.issue_snapshot, repo, ws.branch, ws.base),
         command = %{
           type: "start_run",
           run_id: run.id,
           cwd: ws.path,
           prompt: prompt,
           models: models
         },
         {:ok, _} <- Runner.call(command) do
      case Runs.get_run!(run_id) do
        %Run{status: "failed"} -> Runner.call(%{type: "abort", run_id: run_id})
        %Run{status: "provisioning"} = run -> Runs.update_run(run, %{status: "running"})
        _ -> :ok
      end

      :ok
    end
  end

  @doc false
  def hand_off(run_id) do
    run = Runs.get_run!(run_id)
    repo = run.project.repo

    case run.outcome do
      "completed" ->
        title = "[#{run.issue_key}] #{run.issue_snapshot["summary"]}"
        base = Workspace.base_branch(repo, run.workspace_path)

        with {:ok, true} <- GitHub.branch_exists?(repo, run.branch),
             {:ok, url} <-
               GitHub.find_or_create_pr(repo, run.branch, base, title, pr_description(run)),
             {:ok, _} <- GitHub.transition(run.project, run.issue_key, run.project.handoff_label) do
          {:ok, _} = Runs.update_run(run, %{status: "completed", pr_url: url})
          :ok
        else
          {:ok, false} -> {:error, "the agent finished, but branch #{run.branch} was not pushed"}
          error -> error
        end

      _ ->
        {:ok, _} = Runs.update_run(run, %{status: "failed", error: run.error || "the run failed"})
        :ok
    end
  end

  defp record_setup(_run, nil), do: :ok

  defp record_setup(run, output),
    do: Runs.record_note(run.id, "setup", %{"title" => "Setup script", "text" => output})

  defp pr_description(run) do
    summary = (run.summary || "") |> String.replace(~r/\n*\s*DONE\s*\z/, "") |> String.trim()

    "#{summary}\n\nCloses ##{GitHub.number(run.issue_key)}\n\n---\nOpened by Conductor (run #{run.id})."
  end
end
