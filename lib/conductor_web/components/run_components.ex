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

  @doc "Turns a persisted `Conductor.Runs.Event` into a stream item."
  def item(%Conductor.Runs.Event{} = event) do
    %{id: item_dom_id(event.conversation, event.entry), kind: event.kind, payload: event.payload}
  end

  @doc "Turns a live `message_end` entry into a stream item."
  def item(conversation, %{"id" => id, "kind" => kind} = entry) do
    %{id: item_dom_id(conversation, "e:#{id}"), kind: kind, payload: entry}
  end

  attr :item, :map, required: true

  def transcript_item(%{item: %{kind: "pi.user"}} = assigns) do
    ~H"""
    <div class="rounded-box bg-base-200 p-4">
      <div class="mb-2 text-xs font-semibold uppercase tracking-wide text-base-content/60">Input</div>
      <div class="whitespace-pre-wrap text-sm">{message_text(@item.payload)}</div>
    </div>
    """
  end

  def transcript_item(%{item: %{kind: "pi.assistant"}} = assigns) do
    assigns = assign(assigns, :blocks, message(assigns.item.payload)["content"] || [])

    ~H"""
    <div class="space-y-2 px-1">
      <%= for block <- @blocks do %>
        <%= case block["type"] do %>
          <% "text" -> %>
            <div class="whitespace-pre-wrap text-sm leading-relaxed">{block["text"]}</div>
          <% "thinking" -> %>
            <details :if={block["thinking"] not in [nil, ""]} class="text-xs text-base-content/60">
              <summary class="cursor-pointer">thinking</summary>
              <div class="mt-1 whitespace-pre-wrap">{block["thinking"]}</div>
            </details>
          <% "toolCall" -> %>
            <div class="flex items-start gap-2 font-mono text-xs text-base-content/80">
              <.icon
                name="hero-wrench-screwdriver-micro"
                class="mt-0.5 size-3.5 shrink-0 text-primary"
              />
              <span class="font-semibold">{block["name"]}</span>
              <span class="line-clamp-3 break-all">{tool_args(block["arguments"])}</span>
            </div>
          <% _ -> %>
        <% end %>
      <% end %>
      <div :if={message(@item.payload)["errorMessage"]} class="text-sm text-error">
        {message(@item.payload)["errorMessage"]}
      </div>
    </div>
    """
  end

  def transcript_item(%{item: %{kind: "pi.tool-result"}} = assigns) do
    ~H"""
    <details class={[
      "rounded-box border px-3 py-2 text-xs",
      if(message(@item.payload)["isError"], do: "border-error/40", else: "border-base-300")
    ]}>
      <summary class="cursor-pointer font-mono text-base-content/70">
        {message(@item.payload)["toolName"]} result
      </summary>
      <pre class="mt-2 max-h-96 overflow-auto whitespace-pre-wrap break-all">{truncate(message_text(@item.payload), 8000)}</pre>
    </details>
    """
  end

  def transcript_item(%{item: %{kind: "conductor.note"}} = assigns) do
    ~H"""
    <details class="rounded-box border border-base-300 px-3 py-2 text-xs">
      <summary class="cursor-pointer font-semibold">{@item.payload["title"]}</summary>
      <pre class="mt-2 max-h-96 overflow-auto whitespace-pre-wrap">{truncate(@item.payload["text"], 8000)}</pre>
    </details>
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
