defmodule Conductor.Runs do
  @moduledoc """
  Runs, their persisted transcripts, and their questions.

  Changes are broadcast on `"runs"` (`{:run_updated, run}`) and `"run:<id>"` (`{:run_updated, run}`,
  `{:agent_event, payload}`, `{:question, question}`). Streaming deltas only travel over PubSub; finished messages and
  tool starts are also persisted, upserted by `(run_id, conversation, entry)`.
  """
  use Ash.Domain
  require Ash.Query
  import Ecto.Query
  require Logger
  alias Conductor.Repo
  alias Conductor.Runs.{Event, Question, Run}

  resources do
    resource Run
    resource Question
    resource Event
  end

  @pubsub Conductor.PubSub
  @active ~w(provisioning running handing_off)a

  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, "runs")
  def subscribe(run_id), do: Phoenix.PubSub.subscribe(@pubsub, "run:" <> run_id)
  def unsubscribe(run_id), do: Phoenix.PubSub.unsubscribe(@pubsub, "run:" <> run_id)

  ## Runs

  def list_runs(limit \\ 200) do
    Run
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.Query.load(:project)
    |> Ash.read!()
  end

  @status_groups %{
    all: nil,
    running: ~w(running provisioning handing_off)a,
    waiting: ~w(waiting_for_input)a,
    completed: ~w(completed)a,
    failed: ~w(failed)a,
    picked_up: ~w(picked_up)a
  }

  @doc "The filter groups of the runs list, in display order."
  def status_groups, do: [:all, :running, :waiting, :completed, :failed, :picked_up]

  @doc """
  The newest runs in a status group (`:all` for every status) whose id or issue summary contains `text`,
  case-insensitive.
  """
  def filter_runs(group \\ :all, text \\ "", limit \\ 200) do
    Run
    |> filter_query(group, text)
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.Query.load(:project)
    |> Ash.read!()
  end

  @doc "How many runs `filter_runs/3` matches, without the limit."
  def count_runs(group \\ :all, text \\ ""), do: Run |> filter_query(group, text) |> Ash.count!()

  @doc "The true number of runs per status group, as a map keyed by `status_groups/0`."
  def group_counts, do: Map.new(status_groups(), &{&1, count_runs(&1)})

  @doc "Whether a run belongs to the status group and matches the text, as `filter_runs/3` would say."
  def matches?(%Run{} = run, group, text) do
    needle = text |> String.trim() |> String.downcase()
    summary = (run.issue_snapshot || %{})["summary"] || ""

    group_statuses = Map.fetch!(@status_groups, group)

    (is_nil(group_statuses) or run.status in group_statuses) and
      (needle == "" or String.contains?(String.downcase(run.id), needle) or
         String.contains?(String.downcase(to_string(summary)), needle))
  end

  defp filter_query(query, group, text) do
    query =
      case Map.fetch!(@status_groups, group) do
        nil -> query
        statuses -> Ash.Query.filter(query, status in ^statuses)
      end

    case String.trim(text) do
      "" ->
        query

      text ->
        pattern = "%" <> String.replace(String.downcase(text), ~r/[\\%_]/, "\\\\\\0") <> "%"

        Ash.Query.filter(
          query,
          fragment("lower(?) like ?", id, ^pattern) or
            fragment("lower(?->>'summary') like ?", issue_snapshot, ^pattern)
        )
    end
  end

  def get_run(id), do: Ash.get!(Run, id, load: [project: :repo], not_found_error?: false)
  def get_run!(id), do: Ash.get!(Run, id, load: [project: :repo], not_found_error?: true)

  def list_by_status(statuses) do
    Run
    |> Ash.Query.filter(status in ^statuses)
    |> Ash.Query.sort(:inserted_at)
    |> Ash.Query.load(project: :repo)
    |> Ash.read!()
  end

  @doc "Runs that hold a concurrency slot. A run waiting for a human does not."
  def active_count do
    Run |> Ash.Query.filter(status in ^@active) |> Ash.count!()
  end

  @doc "Runs that wait for a human to answer."
  def waiting_count do
    Run |> Ash.Query.filter(status == :waiting_for_input) |> Ash.count!()
  end

  @doc "The other runs of the same issue as `run`, the first attempt first."
  def other_attempts(%Run{id: id, issue_key: issue_key}) do
    Run
    |> Ash.Query.filter(issue_key == ^issue_key and id != ^id)
    |> Ash.Query.sort(:attempt)
    |> Ash.read!()
  end

  def next_queued do
    Run
    |> Ash.Query.filter(status == :picked_up)
    |> Ash.Query.sort([:inserted_at, :id])
    |> Ash.read!()
    |> Enum.min_by(&priority_rank/1, fn -> nil end)
  end

  # The highest priority first, the oldest among equals; issues without a priority come last.
  defp priority_rank(run), do: (run.issue_snapshot || %{})["priority_rank"] || :infinity

  def open_issue_keys(keys) do
    terminal = Run.terminal_statuses()

    Run
    |> Ash.Query.filter(issue_key in ^keys and status not in ^terminal)
    |> Ash.Query.select(:issue_key)
    |> Ash.read!()
    |> Enum.map(& &1.issue_key)
    |> Enum.uniq()
  end

  def create_run(project, issue_key, snapshot) do
    attempt =
      (Run |> Ash.Query.filter(issue_key == ^issue_key) |> Ash.max!(:attempt) || 0) + 1

    Run
    |> Ash.Changeset.for_create(:create, %{
      id: Run.id_for(issue_key, attempt),
      issue_key: issue_key,
      attempt: attempt,
      project_id: project.id,
      issue_snapshot: snapshot
    })
    |> persist(:create)
  end

  for action <- [
        :pump,
        :provision_end,
        :wait_for_input,
        :resume,
        :settle,
        :complete,
        :hand_off_failed,
        :abort,
        :fail,
        :set_workspace_path,
        :set_branch,
        :clear_workspace
      ] do
    def unquote(action)(%Run{} = run, attrs \\ %{}) do
      update_action(run, unquote(action), attrs)
    end
  end

  defp update_action(run, action, attrs) do
    run
    |> Ash.Changeset.for_update(action, attrs)
    |> persist(:update)
  end

  defp persist(changeset, action), do: apply(Ash, action, [changeset])

  @doc "Terminal runs whose workspace is older than `days`."
  def list_prunable(days) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days, :day)
    terminal = Run.terminal_statuses()

    Run
    |> Ash.Query.filter(
      status in ^terminal and not is_nil(workspace_path) and updated_at < ^cutoff
    )
    |> Ash.read!()
  end

  ## Transcript

  # Row ids break ties for entries without a runner position and are preserved on replay.
  def list_events(run_id, conversation \\ nil) do
    query =
      Event
      |> Ash.Query.filter(run_id == ^run_id)
      |> Ash.Query.sort([:conversation, :position, :id])

    query =
      if is_nil(conversation),
        do: query,
        else: Ash.Query.filter(query, conversation == ^conversation)

    Ash.read!(query)
  end

  @doc "The run's conversations as `{conversation, role}`, the head first."
  def conversations(run_id) do
    # This small grouped Ecto query over the Ash resource returns only conversation/role
    # pairs ordered by first appearance, without loading the entire transcript into memory.
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
    with %Run{} <- Ash.get!(Run, run_id, not_found_error?: false),
         {:ok, _question} <- upsert_question(run_id, qid, text) do
      :ok
    end

    :ok
  end

  def ingest(%{"type" => "run_state", "run_id" => run_id, "status" => status})
      when status in ~w(running waiting_for_input) do
    case Ash.get!(Run, run_id, not_found_error?: false) do
      %Run{} = run ->
        case status do
          "running" -> resume(run)
          "waiting_for_input" -> wait_for_input(run)
        end

      nil ->
        :ok
    end

    :ok
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
      payload: payload
    }
  end

  # System entries repeat the whole tool list and prompt; the transcript does not need them.
  defp upsert_events(rows) do
    rows
    |> Enum.reject(&(&1.kind == "pi.system"))
    |> Enum.chunk_every(100)
    |> Enum.each(fn chunk ->
      result =
        Ash.bulk_create(chunk, Event, :create,
          batch_size: 100,
          transaction: false,
          return_records?: false,
          return_errors?: true,
          notify?: false,
          return_notifications?: false
        )

      if result.error_count > 0 do
        Logger.warning("dropping transcript events: #{inspect(result.errors)}")
      end
    end)
  rescue
    error -> Logger.warning("dropping transcript events: #{Exception.message(error)}")
  end

  ## Questions

  def list_questions(run_id) do
    Question
    |> Ash.Query.filter(run_id == ^run_id)
    |> Ash.Query.sort(:inserted_at)
    |> Ash.read!()
  end

  def get_question(run_id, qid) do
    Question |> Ash.Query.filter(run_id == ^run_id and qid == ^qid) |> Ash.read_one!()
  end

  def upsert_question(run_id, qid, text) do
    Question
    |> Ash.Changeset.for_create(:create, %{run_id: run_id, qid: qid, text: text})
    |> persist(:create)
  end

  def answer_question(%Question{} = question, answer) do
    question
    |> Ash.Changeset.for_update(:update, %{answer: answer, answered_at: DateTime.utc_now(:second)})
    |> persist(:update)
  end

  @doc "Takes over the runner's view of questions after a restart: marks answered ones, adds missing ones."
  def sync_questions(run_id, questions) do
    for %{"qid" => qid, "text" => text, "answered" => answered} <- questions do
      {:ok, question} = upsert_question(run_id, qid, text)

      if answered and is_nil(question.answered_at) do
        question
        |> Ash.Changeset.for_update(:update, %{answered_at: DateTime.utc_now(:second)})
        |> Ash.update!()
      end
    end

    :ok
  end
end
