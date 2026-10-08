defmodule Conductor.Coordinator do
  @moduledoc """
  Moves runs through their lifecycle and keeps at most `max_concurrent` of them busy.

  The database is the queue: `picked_up` runs wait for a slot, the highest priority first, and `provisioning`, `running` and `handing_off` runs
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
      case GitHub.issue(run.project, GitHub.number(run.issue_key)) do
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

  @doc """
  Messages a running head agent, or resumes an in-review run in its original conversation after checking its PR.
  Running agents read messages after their tools. Returns the runner's submission id.
  """
  def message(run_id, text),
    do: GenServer.call(__MODULE__, {:message, run_id, text}, 60_000)

  @doc "Checks a review PR and marks its run done only when GitHub confirms a merge."
  def sync_review(run_id), do: GenServer.call(__MODULE__, {:sync_review, run_id}, 60_000)

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
        Runs.list_by_status(~w(provisioning running waiting_for_input handing_off)a),
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

  def handle_call({:sync_review, run_id}, _from, state) do
    {:reply, refresh_review(Runs.get_run!(run_id)), state}
  end

  def handle_call({:message, run_id, text}, _from, state) do
    run = Runs.get_run!(run_id)

    result =
      cond do
        String.trim(text) == "" -> {:error, :empty_message}
        run.status == :completed -> resume_review(run, text)
        run.status == :running -> send_message(run.id, text)
        true -> {:error, :not_messageable}
      end

    {:reply, result, state}
  end

  def handle_call({:abort, run_id}, _from, state) do
    run = Runs.get_run!(run_id)

    result =
      case run.status do
        status when status in ~w(picked_up provisioning)a ->
          Runs.abort(run)

        status when status in ~w(running waiting_for_input)a ->
          # The runner settles the run as failed; the hand-off then marks it so.
          with {:error, reason} <- Runner.call(%{type: "abort", run_id: run_id}) do
            Logger.warning("coordinator: runner abort of #{run_id} failed: #{inspect(reason)}")
            Runs.abort(run)
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
      %Run{} = run ->
        {:noreply, settle(run, settled, state)}

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

  defp reconcile(%Run{status: :provisioning} = run, _known, state),
    do: start_provision(run, state)

  defp reconcile(%Run{status: :handing_off} = run, _known, state), do: start_handoff(run, state)

  # Running or waiting, but the runner never got (or lost) the run: provision again, which re-sends start_run.
  defp reconcile(run, nil, state), do: start_provision(run, state)

  defp reconcile(run, %{"status" => "settled", "settled" => settled}, state) do
    settle(run, settled, state)
  end

  defp reconcile(run, %{"status" => status} = known, state) do
    Runs.sync_questions(run.id, known["questions"] || [])
    Runs.ingest(%{"type" => "run_state", "run_id" => run.id, "status" => status})
    state
  end

  defp settle(run, settled, state) do
    case Runs.settle(run, %{
           outcome: settled["outcome"],
           summary: settled["summary"],
           error: settled["error"]
         }) do
      {:ok, run} -> start_handoff(run, state)
      {:error, _} -> state
    end
  end

  defp pump(state) do
    settings = Config.get_settings()

    if Runs.active_count() < settings.max_concurrent do
      case Runs.next_queued() do
        nil ->
          state

        run ->
          case Runs.pump(run) do
            {:ok, run} -> pump(start_provision(run, state))
            {:error, _} -> state
          end
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
        Runs.fail(run, %{error: message})

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

    number = GitHub.number(run.issue_key)

    with {:ok, _} <- GitHub.transition(project, number, project.active_status),
         {:ok, github} <- GitHub.run_context(project, run.issue_snapshot),
         {:ok, ws} <- Workspace.provision(repo, Integer.to_string(number), run.issue_snapshot),
         {:ok, run} <- Runs.set_workspace_path(run, %{workspace_path: ws.path}),
         {:ok, run} <- Runs.set_branch(run, %{branch: ws.branch}),
         :ok <- record_setup(run, ws.setup_output),
         # A run that is provisioned again keeps the models it started with: the runner still has them, and the
         # settings may have changed since.
         models when is_map(models) <-
           run.models || Config.run_models(Config.get_settings()) ||
             {:error, "no head model configured"},
         _ <- Conductor.Classification.persist(run),
         prompt = Prompt.render(run.issue_snapshot, project, ws.branch, ws.base),
         command = %{
           type: "start_run",
           run_id: run.id,
           cwd: ws.path,
           prompt: prompt,
           models: models,
           github: github
         },
         # Setup is complete before start_run can emit events. Its reply and first
         # run_state can arrive together, so advancing after the reply loses input events.
         # The models are kept on the run in the step that sends them.
         _ <- Runs.provision_end(Runs.get_run!(run_id), %{models: models}),
         {:ok, _} <- Runner.call(command) do
      case Runs.get_run!(run_id) do
        %Run{status: :failed} -> Runner.call(%{type: "abort", run_id: run_id})
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
        number = GitHub.number(run.issue_key)
        title = "[##{number}] #{run.issue_snapshot["summary"]}"
        base = Workspace.base_branch(repo, run.workspace_path)

        with {:ok, true} <- GitHub.branch_exists?(repo, run.branch),
             {:ok, url} <-
               handoff_pr(run, base, title),
             {:ok, _} <- GitHub.transition(run.project, number, run.project.handoff_status) do
          Runs.complete(run, %{pr_url: url})
          :ok
        else
          {:ok, false} -> {:error, "the agent finished, but branch #{run.branch} was not pushed"}
          error -> error
        end

      _ ->
        Runs.hand_off_failed(run, %{error: run.error || "the run failed"})
        :ok
    end
  end

  defp handoff_pr(%Run{pr_url: nil} = run, base, title),
    do: GitHub.find_or_create_pr(run.project.repo, run.branch, base, title, pr_description(run))

  defp handoff_pr(run, _base, _title) do
    case GitHub.pull_request(run.project.repo, run.pr_url) do
      {:ok, %{"state" => "open", "merged" => false}} -> {:ok, run.pr_url}
      {:ok, %{"merged" => true}} -> {:ok, run.pr_url}
      {:ok, _} -> {:error, :pr_closed}
      error -> error
    end
  end

  defp send_message(run_id, text) do
    with {:ok, %{"submission_id" => id}} <-
           Runner.call(%{type: "message", run_id: run_id, text: text}) do
      {:ok, id}
    end
  end

  defp refresh_review(%Run{status: :completed} = run) do
    with {:ok, pr} <- GitHub.pull_request(run.project.repo, run.pr_url) do
      if pr["merged"] do
        mark_merged(run)
      else
        {:ok, run}
      end
    end
  end

  defp refresh_review(run), do: {:ok, run}

  defp mark_merged(run) do
    # A board permission/configuration failure must not leave a merged PR messageable.
    with {:ok, merged} <- Runs.merge(run) do
      case GitHub.transition(run.project, GitHub.number(run.issue_key), run.project.done_status) do
        {:ok, _} ->
          {:ok, merged}

        {:error, reason} ->
          Logger.warning(
            "coordinator: #{run.id} merged, but moving its issue to Done failed: #{inspect(reason)}"
          )

          {:error, reason}
      end
    end
  end

  defp resume_review(run, text) do
    with {:ok, pr} <- GitHub.pull_request(run.project.repo, run.pr_url),
         :ok <- review_pr_open(run, pr),
         :ok <- review_resumable(run),
         {:ok, _} <-
           GitHub.transition(run.project, GitHub.number(run.issue_key), run.project.active_status),
         {:ok, running} <- Runs.resume_review(run) do
      case Runner.call(%{type: "resume_run", run_id: run.id, text: text}) do
        {:ok, %{"submission_id" => id}} ->
          {:ok, id}

        {:error, _} = error ->
          Runs.return_to_review(running)
          GitHub.transition(run.project, GitHub.number(run.issue_key), run.project.handoff_status)
          error
      end
    end
  end

  defp review_pr_open(run, %{"merged" => true}) do
    # Reject feedback even if updating the board fails; GitHub is authoritative.
    mark_merged(run)
    {:error, :pr_merged}
  end

  defp review_pr_open(_run, %{"state" => "open", "merged" => false}), do: :ok
  defp review_pr_open(_run, _pr), do: {:error, :pr_closed}

  defp review_resumable(run) do
    cond do
      run.status != :completed ->
        {:error, :pr_merged}

      Runs.active_count() >= Config.get_settings().max_concurrent ->
        {:error, :concurrency_limit}

      not is_binary(run.workspace_path) or not File.dir?(run.workspace_path) ->
        {:error, :workspace_unavailable}

      true ->
        :ok
    end
  end

  defp record_setup(_run, nil), do: :ok

  defp record_setup(run, output) do
    if String.trim(output) != "" do
      Runs.record_note(run.id, "setup", %{"title" => "Setup script", "text" => output})
    end
  end

  defp pr_description(run) do
    summary = (run.summary || "") |> String.replace(~r/\n*\s*DONE\s*\z/, "") |> String.trim()

    "#{summary}\n\nCloses ##{GitHub.number(run.issue_key)}\n\n---\nOpened by Conductor (run #{run.id})."
  end
end
