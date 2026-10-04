defmodule Conductor.Runs do
  @moduledoc """
  Runs, their persisted transcripts, and their questions.

  Changes are broadcast on `"runs"` (`{:run_updated, run}`) and `"run:<id>"` (`{:run_updated, run}`,
  `{:agent_event, payload}`, `{:question, question}`). Streaming deltas only travel over PubSub; finished messages and
  tool starts are also persisted, upserted by `(run_id, conversation, entry)`.
  """
  import Ecto.Query
  require Logger
  alias Conductor.Repo
  alias Conductor.Runs.{Event, Question, Run}

  @pubsub Conductor.PubSub
  @active ~w(provisioning running handing_off)

  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, "runs")
  def subscribe(run_id), do: Phoenix.PubSub.subscribe(@pubsub, "run:" <> run_id)
  def unsubscribe(run_id), do: Phoenix.PubSub.unsubscribe(@pubsub, "run:" <> run_id)

  ## Runs

  def list_runs(limit \\ 200) do
    Repo.all(
      from r in Run, order_by: [desc: r.inserted_at, desc: r.id], limit: ^limit, preload: :project
    )
  end

  def get_run(id), do: Repo.get(Run, id) |> Repo.preload(project: :repo)
  def get_run!(id), do: Repo.get!(Run, id) |> Repo.preload(project: :repo)

  def list_by_status(statuses) do
    Repo.all(
      from r in Run,
        where: r.status in ^statuses,
        order_by: r.inserted_at,
        preload: [project: :repo]
    )
  end

  @doc "Runs that hold a concurrency slot. A run waiting for a human does not."
  def active_count, do: Repo.aggregate(from(r in Run, where: r.status in @active), :count)

  def next_queued do
    Repo.one(
      from r in Run, where: r.status == "picked_up", order_by: [r.inserted_at, r.id], limit: 1
    )
  end

  def open_issue_keys(keys) do
    terminal = Run.terminal_statuses()

    Repo.all(
      from r in Run,
        where: r.issue_key in ^keys and r.status not in ^terminal,
        select: r.issue_key,
        distinct: true
    )
  end

  def create_run(project, issue_key, snapshot) do
    attempt =
      (Repo.one(from r in Run, where: r.issue_key == ^issue_key, select: max(r.attempt)) || 0) + 1

    %Run{
      id: Run.id_for(issue_key, attempt),
      issue_key: issue_key,
      attempt: attempt,
      project_id: project.id
    }
    |> Run.changeset(%{status: "picked_up", issue_snapshot: snapshot})
    |> Repo.insert()
    |> tap_ok(&broadcast/1)
  end

  def update_run(%Run{} = run, attrs) do
    run
    |> Run.changeset(attrs)
    |> Repo.update()
    |> tap_ok(&broadcast/1)
  end

  @doc "Terminal runs whose workspace is older than `days`."
  def list_prunable(days) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days, :day)
    terminal = Run.terminal_statuses()

    Repo.all(
      from r in Run,
        where: r.status in ^terminal and not is_nil(r.workspace_path) and r.updated_at < ^cutoff
    )
  end

  defp broadcast(%Run{} = run) do
    run = Repo.preload(run, :project)
    Phoenix.PubSub.broadcast(@pubsub, "runs", {:run_updated, run})
    Phoenix.PubSub.broadcast(@pubsub, "run:" <> run.id, {:run_updated, run})
  end

  ## Transcript

  def list_events(run_id, conversation \\ nil) do
    query =
      from e in Event, where: e.run_id == ^run_id, order_by: [e.conversation, e.position, e.id]

    query = if conversation, do: where(query, [e], e.conversation == ^conversation), else: query
    Repo.all(query)
  end

  @doc "The run's conversations as `{conversation, role}`, the head first."
  def conversations(run_id) do
    Repo.all(
      from e in Event,
        where: e.run_id == ^run_id,
        group_by: [e.conversation, e.role],
        order_by: [min(e.id)],
        select: {e.conversation, e.role}
    )
  end

  @doc "Adds a note from Conductor itself (such as setup output) to the run's transcript, as conversation 0."
  def record_note(run_id, key, payload) do
    upsert_events([row(run_id, 0, "conductor", "n:" <> key, nil, "conductor.note", payload)])
    :ok
  end

  @doc "Stores what a runner event says about a run and rebroadcasts it."
  def ingest(%{"type" => "agent_event", "run_id" => run_id} = message) do
    %{"conversation" => conversation, "role" => role, "event" => event} = message
    persist(run_id, conversation, role, event)
    payload = %{conversation: conversation, role: role, event: event}
    Phoenix.PubSub.broadcast(@pubsub, "run:" <> run_id, {:agent_event, payload})
  end

  def ingest(%{"type" => "question", "run_id" => run_id, "qid" => qid, "text" => text}) do
    with %Run{} <- Repo.get(Run, run_id), {:ok, question} <- upsert_question(run_id, qid, text) do
      Phoenix.PubSub.broadcast(@pubsub, "run:" <> run_id, {:question, question})
    end

    :ok
  end

  def ingest(%{"type" => "run_state", "run_id" => run_id, "status" => status})
      when status in ~w(running waiting_for_input) do
    case Repo.get(Run, run_id) do
      %Run{status: current} = run
      when current in ~w(running waiting_for_input) and current != status ->
        update_run(run, %{status: status})

      _ ->
        :ok
    end
  end

  def ingest(_event), do: :ok

  defp persist(run_id, conversation, role, %{"type" => "snapshot", "entries" => entries}) do
    entries |> Enum.map(&entry_row(run_id, conversation, role, &1)) |> upsert_events()
  end

  defp persist(run_id, conversation, role, %{"type" => "message_end", "entry" => entry}) do
    upsert_events([entry_row(run_id, conversation, role, entry)])
  end

  defp persist(run_id, conversation, role, %{"type" => "tool_execution_start"} = event) do
    payload = Map.take(event, ["toolCallId", "toolName", "args"])

    upsert_events([
      row(run_id, conversation, role, "t:" <> event["toolCallId"], nil, "tool_start", payload)
    ])
  end

  defp persist(_run_id, _conversation, _role, _event), do: :ok

  defp entry_row(run_id, conversation, role, %{"id" => id, "kind" => kind} = entry) do
    row(run_id, conversation, role, "e:#{id}", id, kind, entry)
  end

  defp row(run_id, conversation, role, entry, position, kind, payload) do
    %{
      run_id: run_id,
      conversation: conversation,
      role: role,
      entry: entry,
      position: position,
      kind: kind,
      payload: payload,
      inserted_at: DateTime.utc_now(:second)
    }
  end

  # System entries repeat the whole tool list and prompt; the transcript does not need them.
  defp upsert_events(rows) do
    rows
    |> Enum.reject(&(&1.kind == "pi.system"))
    |> Enum.chunk_every(100)
    |> Enum.each(fn chunk ->
      Repo.insert_all(Event, chunk,
        on_conflict: {:replace, [:payload, :kind, :position, :role]},
        conflict_target: [:run_id, :conversation, :entry]
      )
    end)
  rescue
    error -> Logger.warning("dropping transcript events: #{Exception.message(error)}")
  end

  ## Questions

  def list_questions(run_id) do
    Repo.all(from q in Question, where: q.run_id == ^run_id, order_by: q.inserted_at)
  end

  def get_question(run_id, qid), do: Repo.get_by(Question, run_id: run_id, qid: qid)

  def upsert_question(run_id, qid, text) do
    case get_question(run_id, qid) do
      nil -> Repo.insert(%Question{run_id: run_id, qid: qid, text: text})
      question -> {:ok, question}
    end
  end

  def answer_question(%Question{} = question, answer) do
    question
    |> Ecto.Changeset.change(answer: answer, answered_at: DateTime.utc_now(:second))
    |> Repo.update()
    |> tap_ok(&Phoenix.PubSub.broadcast(@pubsub, "run:" <> &1.run_id, {:question, &1}))
  end

  @doc "Takes over the runner's view of questions after a restart: marks answered ones, adds missing ones."
  def sync_questions(run_id, questions) do
    for %{"qid" => qid, "text" => text, "answered" => answered} <- questions do
      {:ok, question} = upsert_question(run_id, qid, text)

      if answered and is_nil(question.answered_at) do
        question
        |> Ecto.Changeset.change(answered_at: DateTime.utc_now(:second))
        |> Repo.update!()
      end
    end

    :ok
  end

  defp tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_ok(other, _fun), do: other
end
