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
     |> assign(inbox: [], sent: %{})
     |> assign_questions()
     |> select(default_conversation(conversations))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_page={:runs} waiting_count={@waiting_count}>
      <%!-- Fills the window below the header (2.5rem and its border), padding included, so the
      transcript scrolls in its own frame and the run's header, questions and tabs stay in view. --%>
      <div id="run" class="flex h-[calc(100dvh-2.5rem-1px)] flex-col gap-6 p-4 sm:p-6">
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

          <div
            :if={@live_thinking != "" or @live_text != "" or @live_tools != %{}}
            id="live"
            class="space-y-3"
          >
            <.reasoning
              :if={@live_thinking != ""}
              id="live-thinking"
              text={@live_thinking}
              streaming={@live_text == "" and @live_tools == %{}}
            />
            <.chat_message :if={@live_text != ""} from="agent" text={@live_text} />
            <.tool
              :for={{call_id, tool} <- @live_tools}
              :if={tool.output != ""}
              id={"live-tool-#{call_id}"}
              name={tool.name}
              args={tool.args}
              output={tool.output}
              streaming
            />
          </div>

          <%!-- The agent is at work, with nothing to show for it yet; a group of steps it is adding to says so itself. --%>
          <div
            :if={
              @busy and @tail == nil and @run.status == :running and @live_thinking == "" and
                @live_text == "" and
                @live_tools == %{}
            }
            id="indicator"
            class="text-base-content/40"
          >
            <span class="loading loading-dots loading-sm" aria-label="The agent is working"></span>
          </div>
        </.message_scroller>

        <%!-- The oldest open question is answered here. Without one, what is typed goes to the head agent while it
        works; it waits in the agent's inbox until the tools that are running are done. --%>
        <%= case @open_questions do %>
          <% [q | more] -> %>
            <.chat_prompt id={"answer-#{q.qid}"} phx-submit="answer" placeholder="Your answer">
              <:header>
                <div id={"question-#{q.qid}"} class="flex items-start gap-2">
                  <.icon
                    name="hero-chat-bubble-left-ellipsis-micro"
                    class="mt-0.5 size-4 shrink-0 text-warning"
                  />
                  <div class="min-w-0">
                    <div class="text-xs font-medium text-warning">
                      The agent asks
                      <span :if={more != []} id="questions-more" class="font-normal">
                        · {length(more)} more after this
                      </span>
                    </div>
                    <p class="max-h-40 overflow-y-auto whitespace-pre-wrap">{q.text}</p>
                  </div>
                </div>
              </:header>
              <input type="hidden" name="qid" value={q.qid} />
            </.chat_prompt>
          <% [] -> %>
            <.chat_prompt
              :if={not Run.terminal?(@run)}
              id="prompt"
              phx-submit="message"
              placeholder={prompt_placeholder(@run.status, head?(@conversations, @selected))}
              on_stop={@run.status != :handing_off && show_modal("confirm-abort")}
              disabled={@run.status != :running}
            >
              <:header :if={@inbox != []}>
                <ul id="inbox" class="space-y-1">
                  <li
                    :for={%{"id" => id} <- @inbox}
                    id={"inbox-#{id}"}
                    class="flex items-center gap-2 text-base-content/60"
                  >
                    <.icon name="hero-clock-micro" class="size-4 shrink-0" />
                    <span class="min-w-0 truncate">{@sent[id] || "A message"}</span>
                    <span class="shrink-0 text-xs">· waits for the agent</span>
                  </li>
                </ul>
              </:header>
            </.chat_prompt>
        <% end %>
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

  def handle_event("message", %{"text" => text}, socket) do
    case Coordinator.message(socket.assigns.run.id, String.trim(text)) do
      {:ok, id} ->
        {:noreply,
         socket
         |> assign(sent: Map.put(socket.assigns.sent, id, String.trim(text)))
         |> push_event("prompt:sent", %{id: "prompt"})}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not send the message: #{inspect(reason)}")}
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
  def handle_info({:run_updated, %{id: id}}, %{assigns: %{run: %{id: other}}} = socket)
      when id != other,
      do: {:noreply, socket}

  def handle_info({:run_updated, run}, socket) do
    run = Runs.get_run!(run.id)
    socket = if Run.terminal?(run), do: socket |> close_tail() |> assign(inbox: []), else: socket
    {:noreply, assign(socket, run: run)}
  end

  def handle_info({:question, _question}, socket), do: {:noreply, assign_questions(socket)}

  def handle_info({:agent_event, %{conversation: conversation, role: role, event: event}}, socket) do
    # Messages go to the head agent, whichever conversation is on show.
    socket = if role == "head", do: track_inbox(socket, event), else: socket

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

  # What waits in the head agent's inbox: the messages it has not read yet.
  defp track_inbox(socket, %{"type" => type} = event) when type in ~w(inbox_update snapshot) do
    case event["items"] || event["inbox"] do
      items when is_list(items) ->
        assign(socket, inbox: Enum.reject(items, &(&1["mode"] == "write")))

      _ ->
        socket
    end
  end

  defp track_inbox(socket, _event), do: socket

  # A snapshot follows a runner restart; the database already holds it, so reload from there.
  defp apply_event(socket, conversation, %{"type" => "snapshot"}),
    do: select(socket, conversation)

  defp apply_event(socket, _conversation, %{
         "type" => "message_start",
         "message" => %{"role" => "assistant"}
       }) do
    assign(socket, live_text: "", live_thinking: "", busy: true)
  end

  defp apply_event(socket, _conversation, %{"type" => "message_update", "changes" => changes}) do
    {text, thinking} =
      Enum.reduce(changes, {socket.assigns.live_text, socket.assigns.live_thinking}, fn
        %{"type" => "text_delta", "delta" => delta}, {text, thinking} ->
          {text <> delta, thinking}

        %{"type" => "text_start", "block" => %{"text" => start}}, {text, thinking}
        when is_binary(start) ->
          {text <> start, thinking}

        %{"type" => "thinking_delta", "delta" => delta}, {text, thinking} ->
          {text, thinking <> delta}

        %{"type" => "thinking_start", "block" => %{"thinking" => start}}, {text, thinking}
        when is_binary(start) ->
          {text, thinking <> start}

        _, acc ->
          acc
      end)

    assign(socket, live_text: text, live_thinking: thinking, busy: true)
  end

  defp apply_event(socket, conversation, %{
         "type" => "message_end",
         "entry" => %{"kind" => kind} = entry
       }) do
    socket =
      if kind == "pi.assistant",
        do: assign(socket, live_text: "", live_thinking: ""),
        else: socket

    item = item(conversation, entry)

    calling =
      Enum.find(Map.values(socket.assigns.groups), &(result_call_id(entry) in open_calls(&1)))

    cond do
      kind == "pi.system" ->
        socket

      kind == "pi.tool-result" and calling != nil ->
        socket |> assign(busy: true) |> put_group(put_result(calling, entry))

      true ->
        socket = assign(socket, busy: awaiting?(item))
        socket = Enum.reduce(parts(item), socket, &add_part(&2, &1))
        if socket.assigns.busy, do: socket, else: close_tail(socket)
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

    items = Enum.map(items, &item/1)

    busy =
      socket.assigns.run.status == :running and
        latest_attempt?(socket.assigns.conversations, conversation) and
        awaiting?(List.last(items))

    # The agent is still adding to the steps at the end.
    {parts, turn} = transcript(items)

    parts =
      case Enum.split(parts, -1) do
        {parts, [%{kind: "steps"} = tail]} when busy -> parts ++ [%{tail | active: true}]
        {parts, last} -> parts ++ last
      end

    turn = %{
      turn
      | parts: Enum.map(turn.parts, fn part -> Enum.find(parts, part, &(&1.id == part.id)) end)
    }

    groups =
      for %{kind: "steps"} = part <- parts,
          part.active or open_calls(part) != [],
          into: %{},
          do: {part.id, part}

    tail = Enum.find_value(parts, &(&1[:active] && &1.id))

    socket
    |> assign(selected: conversation, live_text: "", live_thinking: "", live_tools: %{})
    |> assign(busy: busy, groups: groups, tail: tail, turn: turn)
    |> stream(:items, parts, reset: true)
  end

  # `groups` keeps the groups of steps that can still change: those waiting for a tool result, to put it on its
  # call, and the one at the end (`tail`), which takes the steps that follow until something else comes.
  defp add_part(socket, %{kind: "steps"} = part) do
    case socket.assigns.groups[socket.assigns.tail] do
      nil -> socket |> assign(tail: part.id) |> put_group(%{part | active: true})
      tail -> put_group(socket, add_steps(tail, part))
    end
  end

  # What the agent is told starts a turn.
  defp add_part(socket, %{kind: "pi.user"} = part) do
    socket
    |> close_tail()
    |> assign(turn: %{started: sent_at(part), parts: []})
    |> stream_insert(:items, part)
  end

  # The answer ends the turn: what led up to it folds into one part. The steps at the end are closed in the fold
  # itself; a stream item that is inserted and deleted in one go would stay.
  defp add_part(socket, %{kind: "text", final: true} = part) do
    turn = socket.assigns.turn
    tail = socket.assigns.groups[socket.assigns.tail]

    closed =
      Enum.map(turn.parts, &if(tail && &1.id == tail.id, do: %{tail | active: false}, else: &1))

    socket =
      case work(%{turn | parts: closed}, part) do
        [%{kind: "work"} = work] ->
          closed
          |> Enum.reduce(socket, &stream_delete(&2, :items, &1))
          |> assign(tail: nil, groups: Map.drop(socket.assigns.groups, Enum.map(closed, & &1.id)))
          |> stream_insert(:items, work)

        _parts ->
          close_tail(socket)
      end

    socket |> assign(turn: %{started: nil, parts: []}) |> stream_insert(:items, part)
  end

  defp add_part(socket, part), do: socket |> close_tail() |> put_part(part)

  defp put_group(socket, group) do
    groups =
      if group.id == socket.assigns.tail or open_calls(group) != [],
        do: Map.put(socket.assigns.groups, group.id, group),
        else: Map.delete(socket.assigns.groups, group.id)

    socket |> assign(groups: groups) |> put_part(group)
  end

  # Shows a part of the turn that is going on, new or changed, and keeps it for when the turn folds.
  defp put_part(socket, part) do
    turn = socket.assigns.turn

    parts =
      if Enum.any?(turn.parts, &(&1.id == part.id)),
        do: Enum.map(turn.parts, &if(&1.id == part.id, do: part, else: &1)),
        else: turn.parts ++ [part]

    socket |> assign(turn: %{turn | parts: parts}) |> stream_insert(:items, part)
  end

  defp close_tail(socket) do
    case socket.assigns.groups[socket.assigns.tail] do
      nil -> assign(socket, tail: nil)
      tail -> socket |> assign(tail: nil) |> put_group(%{tail | active: false})
    end
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

  # An earlier attempt of a subtask is over, whatever its transcript ends with.
  defp latest_attempt?(conversations, conversation) do
    case List.keyfind(conversations, conversation, 0) do
      {_conversation, role} ->
        conversations |> Enum.filter(&(elem(&1, 1) == role)) |> List.last() |> elem(0) ==
          conversation

      nil ->
        true
    end
  end

  defp prompt_placeholder(:running, true), do: "Message the agent"
  defp prompt_placeholder(:running, false), do: "Message the head agent"
  defp prompt_placeholder(:handing_off, _head?), do: "Handing off…"
  defp prompt_placeholder(_status, _head?), do: "Waiting for the agent to start…"

  defp head?(conversations, selected),
    do:
      match?({_conversation, "head"}, List.keyfind(conversations, selected, 0)) or selected == nil

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
