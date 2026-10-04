defmodule ConductorWeb.RunComponents do
  @moduledoc "Pieces shared by the run pages: status badges and transcript items."
  use Phoenix.Component
  import ConductorWeb.CoreComponents, only: [icon: 1]

  attr :status, :string, required: true

  def status_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm whitespace-nowrap", badge_class(@status)]}>
      {String.replace(@status, "_", " ")}
    </span>
    """
  end

  defp badge_class("completed"), do: "badge-success"
  defp badge_class("failed"), do: "badge-error"
  defp badge_class("waiting_for_input"), do: "badge-warning"
  defp badge_class(status) when status in ~w(running provisioning handing_off), do: "badge-info"
  defp badge_class(_), do: "badge-ghost"

  @doc "The DOM id of a persisted or live transcript item."
  def item_dom_id(conversation, entry),
    do: "ev-#{conversation}-#{String.replace(entry, ~r/[^A-Za-z0-9_-]/, "-")}"

  @doc """
  Turns a persisted `Conductor.Runs.Event` into a stream item. `results` holds the results of an assistant
  message's tool calls by call id, so each shows on its call (see `merge_results/1` and `put_result/2`).
  """
  def item(%Conductor.Runs.Event{} = event) do
    %{
      id: item_dom_id(event.conversation, event.entry),
      kind: event.kind,
      payload: event.payload,
      results: %{}
    }
  end

  @doc "Turns a live `message_end` entry into a stream item."
  def item(conversation, %{"id" => id, "kind" => kind} = entry) do
    %{id: item_dom_id(conversation, "e:#{id}"), kind: kind, payload: entry, results: %{}}
  end

  @doc "Moves the tool results among `items` onto the assistant messages that made the calls."
  def merge_results(items) do
    results =
      for %{kind: "pi.tool-result", payload: payload} <- items,
          into: %{},
          do: {result_call_id(payload), payload}

    called = items |> Enum.flat_map(&call_ids/1) |> MapSet.new()

    for item <- items,
        not (item.kind == "pi.tool-result" and result_call_id(item.payload) in called) do
      %{item | results: Map.take(results, call_ids(item))}
    end
  end

  @doc "The ids of the tool calls an assistant message makes."
  def call_ids(%{kind: "pi.assistant", payload: payload}) do
    for %{"type" => "toolCall", "id" => id} <- message(payload)["content"] || [], do: id
  end

  def call_ids(_item), do: []

  @doc "The calls of an assistant message that have no result yet."
  def open_calls(item), do: call_ids(item) -- Map.keys(item.results)

  @doc "The id of the tool call a tool result answers."
  def result_call_id(payload), do: message(payload)["toolCallId"]

  @doc "Adds a tool result to the assistant message that made the call."
  def put_result(item, payload),
    do: %{item | results: Map.put(item.results, result_call_id(payload), payload)}

  attr :from, :string, required: true, values: ~w(agent input)
  attr :text, :string, required: true
  attr :streaming, :boolean, default: false

  @doc """
  A message of the conversation: what the agent was told (`input`) or what it says (`agent`), also while that is
  still streaming in. Everything else in a transcript is indented to line up with the message text.
  """
  def chat_message(assigns) do
    ~H"""
    <div class={["chat", if(@from == "agent", do: "chat-start", else: "chat-end")]}>
      <div class="chat-image avatar avatar-placeholder">
        <div class={[
          "w-7 rounded-full",
          if(@from == "agent",
            do: "bg-primary text-primary-content",
            else: "bg-neutral text-neutral-content"
          )
        ]}>
          <.icon
            name={if @from == "agent", do: "hero-sparkles-micro", else: "hero-user-micro"}
            class="size-4"
          />
        </div>
      </div>
      <div class="chat-header capitalize">{@from}</div>
      <div class="chat-bubble prose prose-sm max-w-[90%]">
        {markdown(@text)}
        <span :if={@streaming} class="loading loading-dots loading-xs"></span>
      </div>
    </div>
    """
  end

  attr :id, :string, default: nil
  attr :class, :any, default: "border-base-300"
  attr :open, :boolean, default: false, doc: "always open, as for a tool that is still running"
  slot :title, required: true
  slot :inner_block

  @doc "A row of the transcript that opens to show more: a tool call and its result, a note, the thinking."
  def fold(%{inner_block: []} = assigns) do
    ~H"""
    <div class={["collapse ml-10 w-auto border", @class]}>
      <div class="collapse-title flex min-h-0 items-start gap-2 px-3 py-2 font-mono text-xs">
        {render_slot(@title)}
      </div>
    </div>
    """
  end

  def fold(%{open: true} = assigns) do
    ~H"""
    <div id={@id} class={["collapse collapse-open ml-10 w-auto border", @class]}>
      <div class="collapse-title flex min-h-0 items-start gap-2 px-3 py-2 font-mono text-xs">
        {render_slot(@title)}
      </div>
      <div class="collapse-content min-w-0 px-3 text-xs">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  def fold(assigns) do
    ~H"""
    <details class={["collapse collapse-arrow ml-10 w-auto border", @class]}>
      <summary class="collapse-title flex min-h-0 items-start gap-2 py-2 ps-3 font-mono text-xs after:top-4!">
        {render_slot(@title)}
      </summary>
      <div class="collapse-content min-w-0 px-3 text-xs">{render_slot(@inner_block)}</div>
    </details>
    """
  end

  attr :item, :map, required: true

  def transcript_item(%{item: %{kind: "pi.user"}} = assigns) do
    ~H"""
    <.chat_message from="input" text={message_text(@item.payload)} />
    """
  end

  def transcript_item(%{item: %{kind: "pi.assistant"}} = assigns) do
    assigns = assign(assigns, :blocks, message(assigns.item.payload)["content"] || [])

    ~H"""
    <div class="space-y-2">
      <%= for block <- @blocks do %>
        <%= case block["type"] do %>
          <% "text" -> %>
            <.chat_message
              :if={String.trim(block["text"] || "") != ""}
              from="agent"
              text={block["text"]}
            />
          <% "thinking" -> %>
            <.fold :if={block["thinking"] not in [nil, ""]}>
              <:title><span class="text-base-content/60">thinking</span></:title>
              <div class="whitespace-pre-wrap text-base-content/60">{block["thinking"]}</div>
            </.fold>
          <% "toolCall" -> %>
            <.tool_call block={block} result={@item.results[block["id"]]} />
          <% _ -> %>
        <% end %>
      <% end %>
      <div :if={message(@item.payload)["errorMessage"]} class="ml-10 text-sm text-error">
        {message(@item.payload)["errorMessage"]}
      </div>
    </div>
    """
  end

  def transcript_item(%{item: %{kind: "pi.tool-result"}} = assigns) do
    ~H"""
    <.fold class={result_border(@item.payload)}>
      <:title>{message(@item.payload)["toolName"]} result</:title>
      <pre class="max-h-96 overflow-auto whitespace-pre-wrap break-all">{truncate(message_text(@item.payload), 8000)}</pre>
    </.fold>
    """
  end

  def transcript_item(%{item: %{kind: "conductor.note"}} = assigns) do
    ~H"""
    <.fold>
      <:title><span class="font-sans font-semibold">{@item.payload["title"]}</span></:title>
      <pre class="max-h-96 overflow-auto whitespace-pre-wrap">{truncate(@item.payload["text"], 8000)}</pre>
    </.fold>
    """
  end

  def transcript_item(%{item: %{kind: "pi.compaction"}} = assigns) do
    ~H"""
    <div class="divider text-xs text-base-content/50">context compacted</div>
    """
  end

  def transcript_item(assigns) do
    ~H"""
    <div class="text-xs text-base-content/50">{@item.kind}</div>
    """
  end

  attr :block, :map, required: true
  attr :result, :map, default: nil

  # A tool call; once its result is in, it opens to show it.
  defp tool_call(%{result: nil} = assigns) do
    ~H"""
    <.fold>
      <:title><.tool_title name={@block["name"]} args={@block["arguments"]} /></:title>
    </.fold>
    """
  end

  defp tool_call(assigns) do
    ~H"""
    <.fold class={result_border(@result)}>
      <:title><.tool_title name={@block["name"]} args={@block["arguments"]} /></:title>
      <pre class="max-h-96 overflow-auto whitespace-pre-wrap break-all">{truncate(message_text(@result), 8000)}</pre>
    </.fold>
    """
  end

  attr :name, :string, required: true
  attr :args, :any, required: true

  defp tool_title(assigns) do
    ~H"""
    <.icon name="hero-wrench-screwdriver-micro" class="mt-0.5 size-3.5 shrink-0 text-primary" />
    <span class="font-semibold">{@name}</span>
    <span class="line-clamp-3 break-all text-base-content/80">{tool_args(@args)}</span>
    """
  end

  defp result_border(payload),
    do: if(message(payload)["isError"], do: "border-error/40", else: "border-base-300")

  @doc """
  Renders Markdown as HTML that is safe to show: the text comes from issues and from the agent, so HTML in it is
  shown as text and what is left is sanitized. A line break in the text stays a line break.
  """
  def markdown(text) do
    text
    |> MDEx.to_html!(
      extension: [strikethrough: true, table: true, autolink: true, tasklist: true],
      render: [hardbreaks: true, escape: true],
      syntax_highlight: nil,
      sanitize: MDEx.Document.default_sanitize_options()
    )
    |> Phoenix.HTML.raw()
  end

  defp message(payload), do: List.first(payload["model"] || []) || %{}

  @doc "The plain text of an entry's message: a string, or the text parts of its content."
  def message_text(payload) do
    case message(payload)["content"] do
      text when is_binary(text) ->
        text

      parts when is_list(parts) ->
        parts |> Enum.filter(&(&1["type"] == "text")) |> Enum.map_join("\n", & &1["text"])

      _ ->
        ""
    end
  end

  def tool_args(args) when is_map(args) do
    case args do
      %{"command" => command} -> command
      %{"path" => path} -> path
      _ -> Jason.encode!(args)
    end
  end

  def tool_args(_), do: ""

  def truncate(nil, _), do: ""
  def truncate(text, max) when byte_size(text) <= max, do: text
  def truncate(text, max), do: binary_part(text, 0, max) <> "\n… (truncated)"
end
