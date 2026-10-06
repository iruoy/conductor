defmodule ConductorWeb.RunLive do
  use ConductorWeb, :live_view
  alias Conductor.{Coordinator, Runs}
  alias Conductor.Runs.Run

  @tool_output_max 4000

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    run = Runs.get_run!(id)
    if connected?(socket), do: Runs.subscribe(id)
    conversations = Runs.conversations(id)

    {:ok,
     socket
     |> assign(page_title: run.id, run: run, conversations: conversations)
     |> assign_questions()
     |> select(default_conversation(conversations))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <%!-- Fills the window below the navbar (4rem and its border) and inside the padding of <main> (2 × 2rem), so the
      transcript scrolls in its own frame and the run's header, questions and tabs stay in view. --%>
      <div id="run" class="flex h-[calc(100dvh-8rem-2px)] flex-col gap-6">
        <.header>
          <span class="font-mono">{@run.id}</span>
          <span class="font-normal">· {(@run.issue_snapshot || %{})["summary"]}</span>
          <:subtitle>
            <span class="inline-flex flex-wrap items-center gap-2">
              <.status_badge status={@run.status} />
              <span :if={@run.branch} class="font-mono">{@run.branch}</span>
              <a :if={@run.pr_url} href={@run.pr_url} target="_blank" class="link link-primary">Pull request</a>
            </span>
          </:subtitle>
          <:actions>
            <button :if={Run.terminal?(@run)} id="retry" phx-click="retry" class="btn btn-sm">Retry</button>
            <button
              :if={not Run.terminal?(@run) and @run.status != :handing_off}
              id="abort"
              phx-click={show_modal("confirm-abort")}
              class="btn btn-sm btn-error btn-outline"
            >
              Abort
            </button>
            <.confirm_modal
              :if={not Run.terminal?(@run) and @run.status != :handing_off}
              id="confirm-abort"
              title="Abort this run?"
              confirm="Abort"
              on_confirm={JS.push("abort")}
            >
              The agent stops and the run is marked as failed.
            </.confirm_modal>
          </:actions>
        </.header>

        <div :if={@run.status == :failed && @run.error} class="alert alert-error text-sm">
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <span class="whitespace-pre-wrap">{@run.error}</span>
        </div>

        <section
          :for={q <- @open_questions}
          id={"question-#{q.qid}"}
          class="card card-border card-sm border-warning"
        >
          <div class="card-body">
            <h2 class="card-title text-sm text-warning">
              <.icon name="hero-chat-bubble-left-ellipsis" class="size-5" /> The agent asks
            </h2>
            <p class="whitespace-pre-wrap text-sm">{q.text}</p>
            <.form
              for={to_form(%{"qid" => q.qid, "text" => ""})}
              id={"answer-#{q.qid}"}
              phx-submit="answer"
            >
              <input type="hidden" name="qid" value={q.qid} />
              <.input type="textarea" name="text" value="" placeholder="Your answer" required />
              <div class="card-actions">
                <.button variant="primary" phx-disable-with="Sending…">Send answer</.button>
              </div>
            </.form>
          </div>
        </section>

        <div :if={@conversations != []} role="tablist" class="tabs tabs-border" id="conversations">
          <button
            :for={{conversation, label} <- tab_labels(@conversations)}
            role="tab"
            id={"tab-#{conversation}"}
            phx-click="select"
            phx-value-conversation={conversation}
            class={["tab font-mono text-xs", @selected == conversation && "tab-active"]}
          >
            {label}
          </button>
        </div>

        <.message_scroller id="transcript-scroller" key={@selected} class="min-h-80 flex-1">
          <div id="transcript" phx-update="stream" class="space-y-4">
            <div
              id="transcript-empty"
              class="hidden py-8 text-center text-sm text-base-content/60 only:block"
            >
              Nothing to show yet.
            </div>
            <div :for={{dom_id, item} <- @streams.items} id={dom_id}>
              <.transcript_item item={item} />
            </div>
          </div>

          <div :if={@live_text != "" or @live_tools != %{}} id="live" class="space-y-2">
            <.chat_message :if={@live_text != ""} from="agent" text={@live_text} streaming />
            <.fold
              :for={{call_id, tool} <- @live_tools}
              id={"live-tool-#{call_id}"}
              class="border-info/40"
              open
            >
              <:title>
                <span class="loading loading-spinner loading-xs text-info"></span>
                <span class="font-semibold">{tool.name}</span>
                <span class="truncate text-base-content/70">{tool_args(tool.args)}</span>
              </:title>
              <pre
                :if={tool.output != ""}
                class="max-h-64 overflow-auto whitespace-pre-wrap break-all"
              >{tool.output}</pre>
            </.fold>
          </div>
        </.message_scroller>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("select", %{"conversation" => conversation}, socket) do
    {:noreply, select(socket, String.to_integer(conversation))}
  end

  def handle_event("answer", %{"qid" => qid, "text" => text}, socket) do
    case Coordinator.answer(socket.assigns.run.id, qid, String.trim(text)) do
      {:ok, _} ->
        {:noreply, socket |> assign_questions() |> put_flash(:info, "Answer sent")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not send the answer: #{inspect(reason)}")}
    end
  end

  def handle_event("abort", _params, socket) do
    case Coordinator.abort(socket.assigns.run.id) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Aborting…")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cannot abort: #{inspect(reason)}")}
    end
  end

  def handle_event("retry", _params, socket) do
    case Coordinator.retry(socket.assigns.run.id) do
      {:ok, run} ->
        {:noreply, push_navigate(socket, to: ~p"/runs/#{run.id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cannot retry: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:run_updated, run}, socket) do
    {:noreply, assign(socket, run: Runs.get_run!(run.id))}
  end

  def handle_info({:question, _question}, socket), do: {:noreply, assign_questions(socket)}

  def handle_info({:agent_event, %{conversation: conversation, role: role, event: event}}, socket) do
    socket =
      if List.keymember?(socket.assigns.conversations, conversation, 0) do
        socket
      else
        conversations = socket.assigns.conversations ++ [{conversation, role}]
        socket = assign(socket, conversations: conversations)
        if socket.assigns.selected, do: socket, else: select(socket, conversation)
      end

    if conversation == socket.assigns.selected do
      {:noreply, apply_event(socket, conversation, event)}
    else
      {:noreply, socket}
    end
  end

  # A snapshot follows a runner restart; the database already holds it, so reload from there.
  defp apply_event(socket, conversation, %{"type" => "snapshot"}),
    do: select(socket, conversation)

  defp apply_event(socket, _conversation, %{
         "type" => "message_start",
         "message" => %{"role" => "assistant"}
       }) do
    assign(socket, live_text: "")
  end

  defp apply_event(socket, _conversation, %{"type" => "message_update", "changes" => changes}) do
    text =
      Enum.reduce(changes, socket.assigns.live_text, fn
        %{"type" => "text_delta", "delta" => delta}, acc ->
          acc <> delta

        %{"type" => "text_start", "block" => %{"text" => text}}, acc when is_binary(text) ->
          acc <> text

        _, acc ->
          acc
      end)

    assign(socket, live_text: text)
  end

  defp apply_event(socket, conversation, %{
         "type" => "message_end",
         "entry" => %{"kind" => kind} = entry
       }) do
    socket = if kind == "pi.assistant", do: assign(socket, live_text: ""), else: socket
    item = item(conversation, entry)
    calling = Enum.find(socket.assigns.calling, &(result_call_id(entry) in open_calls(&1)))

    cond do
      kind == "pi.system" -> socket
      kind == "pi.tool-result" and calling != nil -> insert(socket, put_result(calling, entry))
      true -> insert(socket, item)
    end
  end

  defp apply_event(socket, _conversation, %{"type" => "tool_execution_start"} = event) do
    tool = %{name: event["toolName"], args: event["args"], output: ""}
    assign(socket, live_tools: Map.put(socket.assigns.live_tools, event["toolCallId"], tool))
  end

  defp apply_event(
         socket,
         _conversation,
         %{"type" => "tool_execution_update", "toolCallId" => id} = event
       ) do
    case {socket.assigns.live_tools[id], event["output"]} do
      {tool, output} when tool != nil and is_map(output) ->
        tool = %{tool | output: apply_output(tool.output, output)}
        assign(socket, live_tools: Map.put(socket.assigns.live_tools, id, tool))

      _ ->
        socket
    end
  end

  defp apply_event(socket, _conversation, %{"type" => "tool_execution_end", "toolCallId" => id}) do
    assign(socket, live_tools: Map.delete(socket.assigns.live_tools, id))
  end

  defp apply_event(socket, _conversation, _event), do: socket

  defp apply_output(_current, %{"set" => text}), do: tail(text)

  defp apply_output(current, output) do
    trimmed =
      case output["trimStart"] do
        n when is_integer(n) and n > 0 -> String.slice(current, n..-1//1)
        _ -> current
      end

    tail(trimmed <> (output["append"] || ""))
  end

  defp tail(text) when byte_size(text) > @tool_output_max,
    do: String.slice(text, -@tool_output_max, @tool_output_max)

  defp tail(text), do: text

  defp select(socket, conversation) do
    items =
      if conversation,
        do:
          socket.assigns.run.id
          |> Runs.list_events(conversation)
          |> Enum.reject(&(&1.kind == "tool_start")),
        else: []

    items = items |> Enum.map(&item/1) |> merge_results()

    socket
    |> assign(selected: conversation, live_text: "", live_tools: %{})
    |> assign(calling: Enum.filter(items, &(open_calls(&1) != [])))
    |> stream(:items, items, reset: true)
  end

  # `calling` keeps the assistant messages that still wait for a tool result, to put the result on its call.
  defp insert(socket, item) do
    calling = Enum.reject(socket.assigns.calling, &(&1.id == item.id))
    calling = if open_calls(item) == [], do: calling, else: calling ++ [item]
    socket |> assign(calling: calling) |> stream_insert(:items, item)
  end

  # A subtask's tab is its issue number (`sub:#12` is `#12`); one that ran more than once also counts its attempts.
  defp tab_labels(conversations) do
    attempts = Enum.frequencies_by(conversations, &elem(&1, 1))

    {labels, _seen} =
      Enum.map_reduce(conversations, %{}, fn {conversation, role}, seen ->
        attempt = Map.get(seen, role, 0) + 1
        label = String.replace_prefix(role, "sub:", "")
        label = if attempts[role] > 1, do: "#{label} · attempt #{attempt}", else: label
        {{conversation, label}, Map.put(seen, role, attempt)}
      end)

    labels
  end

  defp default_conversation(conversations) do
    case List.keyfind(conversations, "head", 1) || List.first(conversations) do
      {conversation, _role} -> conversation
      nil -> nil
    end
  end

  defp assign_questions(socket) do
    questions = Runs.list_questions(socket.assigns.run.id)
    assign(socket, open_questions: Enum.filter(questions, &is_nil(&1.answered_at)))
  end
end
