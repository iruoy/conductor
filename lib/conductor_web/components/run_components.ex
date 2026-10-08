defmodule ConductorWeb.RunComponents do
  @moduledoc "Pieces shared by the run pages: the status chip, durations and times, and transcript items."
  use Phoenix.Component
  import ConductorWeb.CoreComponents, only: [icon: 1]

  attr :status, :atom, required: true, doc: "a `Conductor.Runs.Run` status"
  attr :id, :string, default: nil
  attr :class, :any, default: nil

  @doc """
  The status of a run as a pill with a dot, in the colours of the status: under way (`provisioning`, `running`,
  `handing_off`) info, `waiting_for_input` warning, `completed` success, `failed` error, anything else neutral.
  The label is the status in words; `data-status` carries the status itself.
  """
  def status_badge(assigns) do
    ~H"""
    <span
      id={@id}
      data-status={@status}
      class={[
        "badge h-5 gap-[5px] whitespace-nowrap border-0 px-[7px] align-middle text-[11px] font-medium",
        badge_class(@status),
        @class
      ]}
    >
      <span class="size-[5px] rounded-full bg-current"></span>{status_label(@status)}
    </span>
    """
  end

  @doc "A run status in words: `:waiting_for_input` is \"waiting for input\"."
  def status_label(status), do: String.replace(to_string(status), "_", " ")

  defp badge_class(:completed), do: "bg-chip-success-bg text-chip-success-fg"
  defp badge_class(:failed), do: "bg-chip-error-bg text-chip-error-fg"
  defp badge_class(:waiting_for_input), do: "bg-chip-warning-bg text-chip-warning-fg"

  defp badge_class(status) when status in ~w(running provisioning handing_off)a,
    do: "bg-chip-info-bg text-chip-info-fg"

  defp badge_class(_), do: "bg-muted text-fg-neutral"

  @doc """
  How long a run took, to the minute (`<1m`, `21m`, `1h 5m`): from when it was picked up to its last update once
  it is finished, to `now` while it is under way. A run that has not started (`picked_up`) has none: `—`.
  """
  def run_duration(run, now \\ DateTime.utc_now())
  def run_duration(%{status: :picked_up}, _now), do: "—"

  def run_duration(%{status: status} = run, now) do
    ended = if status in Conductor.Runs.Run.terminal_statuses(), do: run.updated_at, else: now
    minutes(DateTime.diff(ended, run.inserted_at, :second))
  end

  defp minutes(seconds) when seconds < 60, do: "<1m"
  defp minutes(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp minutes(seconds), do: "#{div(seconds, 3600)}h #{rem(div(seconds, 60), 60)}m"

  @doc """
  A point in time as the page shows it, in the server's timezone: the time (`14:02`), and the date before it when
  it is not today (`7 Oct 14:02`). Nothing for `nil`.
  """
  def local_time(nil), do: ""

  def local_time(%DateTime{} = at) do
    local =
      at
      |> DateTime.shift_zone!("Etc/UTC")
      |> DateTime.to_naive()
      |> NaiveDateTime.truncate(:second)
      |> NaiveDateTime.to_erl()
      |> :calendar.universal_time_to_local_time()
      |> NaiveDateTime.from_erl!()

    {today, _time} = :calendar.local_time()
    today? = NaiveDateTime.to_date(local) == Date.from_erl!(today)
    Calendar.strftime(local, if(today?, do: "%H:%M", else: "%-d %b %H:%M"))
  end

  @doc "The DOM id of a persisted or live transcript item."
  def item_dom_id(conversation, entry),
    do: "ev-#{conversation}-#{String.replace(entry, ~r/[^A-Za-z0-9_-]/, "-")}"

  @doc "Turns a persisted `Conductor.Runs.Event` into a transcript item."
  def item(%Conductor.Runs.Event{} = event) do
    %{
      id: item_dom_id(event.conversation, event.entry),
      kind: event.kind,
      payload: event.payload,
      context_entries: context_entry(event.conversation, event.payload)
    }
  end

  @doc "Turns a live `message_end` entry into a transcript item."
  def item(conversation, %{"id" => id, "kind" => kind} = entry) do
    %{
      id: item_dom_id(conversation, "e:#{id}"),
      kind: kind,
      payload: entry,
      context_entries: context_entry(conversation, entry)
    }
  end

  defp context_entry(conversation, %{"id" => id, "kind" => kind}) when is_integer(id),
    do: [%{conversation: conversation, entry: id, kind: kind}]

  defp context_entry(_conversation, _payload), do: []

  @doc """
  What a list of transcript items shows: the agent's texts and, between them, what it did to get there. Its
  thinking and its tool calls are steps; the steps between two texts make one group (kind `steps`), also when
  they come from several messages, and each tool result goes onto its call. The first thing it was told is marked
  `first`: that is the issue.
  """
  def transcript(items), do: items |> first_prompt() |> unfolded() |> fold_turns()

  # The prompt a conversation starts with is the issue; what follows was sent by a human.
  defp first_prompt(items) do
    case Enum.find_index(items, &(&1.kind == "pi.user")) do
      nil -> items
      index -> List.update_at(items, index, &Map.put(&1, :first, true))
    end
  end

  defp unfolded(items) do
    results =
      for %{kind: "pi.tool-result", payload: payload} <- items,
          into: %{},
          do: {result_call_id(payload), payload}

    parts = Enum.flat_map(items, &parts/1)
    called = parts |> Enum.flat_map(&call_ids/1) |> MapSet.new()

    parts
    |> Enum.reject(&(&1.kind == "pi.tool-result" and result_call_id(&1.payload) in called))
    |> join_steps()
    |> Enum.map(&put_results(&1, results))
  end

  @doc """
  Folds what the agent did on the way to an answer into one part of kind `work`, per turn: from what it was told
  to the text it stopped with. The answer stays; a turn without one, as while the agent works or after it was
  stopped, stays as it is. Returns the parts and the turn at the end, which may still get its answer: when it
  started and what it shows so far.
  """
  def fold_turns(parts) do
    {shown, turn} =
      Enum.reduce(parts, {[], %{started: nil, parts: []}}, fn
        %{kind: "pi.user"} = part, {shown, turn} ->
          {[part | Enum.reverse(turn.parts, shown)], %{started: sent_at(part), parts: []}}

        %{kind: "text", final: true} = part, {shown, turn} ->
          {[part | Enum.reverse(work(turn, part), shown)], %{started: nil, parts: []}}

        part, {shown, turn} ->
          {shown, %{turn | parts: turn.parts ++ [part]}}
      end)

    {Enum.reverse(shown) ++ turn.parts, turn}
  end

  @doc "What a turn shows once `answer` ends it: its parts as one, unless there is hardly anything to fold."
  def work(%{parts: parts}, _answer) when length(parts) < 2, do: parts

  def work(%{parts: [first | _] = parts, started: started}, answer) do
    ms = if started && answer.at, do: answer.at - started
    [%{id: "#{first.id}-work", kind: "work", parts: parts, ms: ms}]
  end

  @doc "When the agent was told something, in milliseconds."
  def sent_at(%{kind: "pi.user", payload: payload}), do: message(payload)["timestamp"]

  @doc """
  The parts an item shows as. An assistant message falls apart into its texts and the groups of steps around
  them; anything else is its own part.
  """
  def parts(%{kind: "pi.assistant", id: id, payload: payload} = item) do
    message = message(payload)

    parts =
      (message["content"] || [])
      |> Enum.with_index()
      |> Enum.flat_map(fn {block, index} -> part("#{id}-#{index}", block) end)
      |> join_steps()

    timing =
      if valid_duration?(message["durationMs"]) do
        [
          %{
            id: "#{id}-timing",
            kind: "model-timing",
            ms: message["durationMs"],
            model: message["model"] || "Model"
          }
        ]
      else
        []
      end

    shown =
      timing ++
        case stop_notice(message) do
          nil -> answer(parts, message)
          notice -> parts ++ [%{id: "#{id}-error", kind: "error", text: notice}]
        end

    shown = if shown == [] and item[:context_entries] not in [nil, []], do: [item], else: shown
    Enum.map(shown, &Map.put(&1, :context_entries, item[:context_entries] || []))
  end

  def parts(item), do: [item]

  # The text a message stops with is the answer of its turn.
  defp answer(parts, %{"stopReason" => "stop"} = message) do
    case List.last(parts) do
      %{kind: "text"} = text ->
        List.replace_at(parts, -1, %{text | final: true, at: message["timestamp"]})

      _ ->
        parts
    end
  end

  defp answer(parts, _message), do: parts

  # How a message that did not end well says so; the wording is pi's.
  defp stop_notice(%{"stopReason" => "aborted"}), do: "Operation aborted"

  defp stop_notice(%{"stopReason" => "error"} = message),
    do: "Error: #{message["errorMessage"] || "Unknown error"}"

  defp stop_notice(%{"stopReason" => "length"}), do: "Response was truncated before completion."
  defp stop_notice(message), do: message["errorMessage"]

  defp part(id, %{"type" => "text", "text" => text}) when is_binary(text),
    do:
      if(String.trim(text) == "",
        do: [],
        else: [%{id: id, kind: "text", text: text, final: false, at: nil}]
      )

  defp part(id, %{"type" => "thinking", "thinking" => text}) when text not in [nil, ""],
    do: [steps(id, %{type: :thinking, text: text})]

  defp part(id, %{"type" => "toolCall"} = block) do
    step = %{
      type: :tool,
      id: block["id"],
      name: block["name"],
      args: block["arguments"],
      result: nil
    }

    [steps(id, step)]
  end

  defp part(_id, _block), do: []

  # `active` is set on the group the agent is still adding to.
  defp steps(id, step), do: %{id: id, kind: "steps", steps: [step], active: false}

  defp join_steps(parts) do
    parts
    |> Enum.reduce([], fn
      %{kind: "steps"} = part, [%{kind: "steps"} = last | rest] -> [add_steps(last, part) | rest]
      part, joined -> [part | joined]
    end)
    |> Enum.reverse()
  end

  @doc "Adds the steps of one group to another."
  def add_steps(group, %{kind: "steps", steps: steps} = part) do
    group
    |> Map.put(:steps, Enum.reduce(steps, group.steps, &add_step(&2, &1)))
    |> Map.put(
      :context_entries,
      Enum.uniq((group[:context_entries] || []) ++ (part[:context_entries] || []))
    )
  end

  # Thinking that goes on is one thought.
  defp add_step(steps, %{type: :thinking, text: text} = step) do
    case List.last(steps) do
      %{type: :thinking} = last ->
        List.replace_at(steps, -1, %{last | text: last.text <> "\n\n" <> text})

      _ ->
        steps ++ [step]
    end
  end

  defp add_step(steps, step), do: steps ++ [step]

  @doc "The ids of the tool calls in a group of steps."
  def call_ids(%{kind: "steps", steps: steps}), do: for(%{type: :tool, id: id} <- steps, do: id)
  def call_ids(_part), do: []

  @doc "The calls in a group of steps that have no result yet."
  def open_calls(%{kind: "steps", steps: steps}),
    do: for(%{type: :tool, id: id, result: nil} <- steps, do: id)

  def open_calls(_part), do: []

  @doc "The id of the tool call a tool result answers."
  def result_call_id(payload), do: message(payload)["toolCallId"]

  @doc "Puts a tool result onto its call in a group of steps."
  def put_result(group, payload), do: put_results(group, %{result_call_id(payload) => payload})

  defp put_results(%{kind: "steps"} = group, results) do
    steps =
      Enum.map(group.steps, fn
        %{type: :tool, id: id} = step when is_map_key(results, id) ->
          %{step | result: results[id]}

        step ->
          step
      end)

    refs = group[:context_entries] || []
    conversation = Enum.find_value(refs, & &1.conversation)

    results_refs =
      if conversation,
        do:
          Enum.flat_map(
            Map.values(Map.take(results, call_ids(group))),
            &context_entry(conversation, &1)
          ),
        else: []

    group |> Map.put(:steps, steps) |> Map.put(:context_entries, Enum.uniq(refs ++ results_refs))
  end

  defp put_results(part, _results), do: part

  attr :id, :string, required: true

  attr :key, :any,
    default: nil,
    doc: "what is shown; when it changes the scroller goes back to the end"

  attr :class, :any, default: nil
  slot :inner_block, required: true

  @doc """
  The scrolling frame of a transcript. It opens at the end and follows what comes in for as long as the reader
  stays there; scrolling away lets go, and the button or scrolling back to the end picks it up again.
  """
  def message_scroller(assigns) do
    ~H"""
    <div id={@id} phx-hook=".MessageScroller" data-scroller-key={@key} class={["relative", @class]}>
      <div
        data-scroller-viewport
        role="region"
        aria-label="Messages"
        tabindex="0"
        class="h-full overflow-y-auto overscroll-contain pr-2 outline-none"
      >
        <div
          data-scroller-content
          role="log"
          aria-relevant="additions"
          class="mx-auto max-w-4xl space-y-4 pb-2"
        >
          {render_slot(@inner_block)}
        </div>
      </div>
      <button
        type="button"
        data-scroller-button
        data-active="false"
        inert
        tabindex="-1"
        aria-label="Jump to latest"
        class="btn btn-circle btn-sm absolute bottom-3 left-1/2 -translate-x-1/2 shadow-md transition duration-200 data-[active=false]:pointer-events-none data-[active=false]:translate-y-2 data-[active=false]:opacity-0"
      >
        <.icon name="hero-arrow-down-micro" class="size-4" />
      </button>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".MessageScroller">
      // How close to the end, in pixels, still counts as being there.
      const EDGE = 8

      export default {
        mounted() {
          this.viewport = this.el.querySelector("[data-scroller-viewport]")
          this.content = this.el.querySelector("[data-scroller-content]")
          this.button = this.el.querySelector("[data-scroller-button]")
          this.key = this.el.dataset.scrollerKey
          this.following = true
          // A smooth scroll to the end passes positions that are not the end; those must not let go.
          this.jumping = false

          this.viewport.addEventListener("scroll", () => {
            if (this.atEnd()) {
              this.following = true
              this.jumping = false
            } else if (!this.jumping) {
              this.following = false
            }
            this.sync()
          }, {passive: true})

          // The reader taking over ends a jump, so that the scroll that follows lets go.
          for (const type of ["wheel", "touchstart", "pointerdown", "keydown"]) {
            this.viewport.addEventListener(type, () => this.jumping = false, {passive: true})
          }

          this.button.addEventListener("click", () => {
            const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches
            this.following = true
            this.jumping = !still
            this.viewport.scrollTo({top: this.viewport.scrollHeight, behavior: still ? "auto" : "smooth"})
            this.viewport.focus({preventScroll: true})
          })

          // Streaming text, a fold opening and the frame itself resizing all move the end.
          this.observer = new ResizeObserver(() => this.follow())
          this.observer.observe(this.content)
          this.observer.observe(this.viewport)
          this.follow()
        },

        updated() {
          if (this.el.dataset.scrollerKey !== this.key) {
            this.key = this.el.dataset.scrollerKey
            this.following = true
          }
          this.follow()
        },

        destroyed() {
          this.observer.disconnect()
        },

        atEnd() {
          const {scrollHeight, scrollTop, clientHeight} = this.viewport
          return scrollHeight - scrollTop - clientHeight <= EDGE
        },

        follow() {
          if (this.following) {
            this.jumping = false
            this.viewport.scrollTop = this.viewport.scrollHeight
          }
          this.sync()
        },

        // A patch puts the button back as the server rendered it, so this runs after each one too.
        sync() {
          const active = !this.atEnd()
          this.button.dataset.active = String(active)
          this.button.inert = !active
        }
      }
    </script>
    """
  end

  attr :from, :string, required: true, values: ~w(agent input)
  attr :text, :string, required: true
  attr :first, :boolean, default: false, doc: "the prompt the conversation starts with: the issue"

  @doc """
  A message of the conversation: a square badge, who it is from, and the text. What the agent was told (`input`)
  is the issue for the first prompt and you for the later ones; what it says (`agent`) is the agent.
  """
  def chat_message(assigns) do
    assigns =
      assign(assigns,
        who:
          case assigns do
            %{from: "agent"} -> %{badge: "AG", label: "Agent", color: "bg-info text-info-content"}
            %{first: true} -> %{badge: "IS", label: "Issue", color: "bg-muted text-fg-neutral"}
            _ -> %{badge: "YOU", label: "You", color: "bg-muted text-fg-neutral"}
          end
      )

    ~H"""
    <article data-from={@from} class="flex gap-2">
      <div
        data-badge
        aria-hidden="true"
        class={[
          "flex size-6 shrink-0 items-center justify-center rounded-field text-[10px] font-semibold",
          String.length(@who.badge) > 2 && "tracking-tighter",
          @who.color
        ]}
      >
        {@who.badge}
      </div>
      <div class="min-w-0 flex-1 pt-px">
        <div data-label class="mb-px text-[11px] text-fg-secondary">{@who.label}</div>
        <div class="prose prose-sm max-w-none text-[13px] leading-[1.45] text-base-content">
          {markdown(@text)}
        </div>
      </div>
    </article>
    """
  end

  attr :id, :string, default: nil
  attr :text, :string, required: true

  attr :suffix, :string,
    default: nil,
    doc: "secondary text after the label, as the command of a tool call"

  attr :note, :any, default: nil, doc: "a remark after the label, as how much of it failed"
  attr :meta, :string, default: nil, doc: "what stands at the far end, as how long it took"
  attr :streaming, :boolean, default: false, doc: "still going on: a dot pulses before the label"
  attr :open, :boolean, default: false
  slot :inner_block, required: true

  @doc """
  A line of the transcript for what the agent did besides talking: a chevron, what it was, and how long it took at
  the far end. It opens to show what is inside.
  """
  def row(assigns) do
    ~H"""
    <details id={@id} open={@open} class="rounded-field border border-base-300 bg-base-100">
      <summary class={[
        "flex h-[26px] min-w-0 cursor-pointer list-none items-center gap-1.5 rounded-field px-2 text-xs",
        "text-fg-secondary transition-colors hover:text-base-content [&::-webkit-details-marker]:hidden"
      ]}>
        <.icon
          name="hero-chevron-right-micro"
          class="size-3 shrink-0 transition-transform duration-150 [details[open]>summary>&]:rotate-90 motion-reduce:transition-none"
        />
        <.pulse_dot :if={@streaming} class="size-1.5 bg-dot-blue" />
        <span class="truncate">
          <span data-row-text>{@text}</span>
          <span :if={@suffix not in [nil, ""]} class="ms-1 font-mono text-[11.5px]">{@suffix}</span>
          <span :if={@note not in [nil, false, ""]} data-row-note class="text-chip-error-fg">
            · {@note}
          </span>
        </span>
        <span class="flex-1"></span>
        <span :if={@meta} data-row-meta class="shrink-0 tabular-nums text-fg-tertiary">{@meta}</span>
      </summary>
      <div class="border-t border-base-300 p-2">{render_slot(@inner_block)}</div>
    </details>
    """
  end

  attr :class, :any, default: nil
  attr :pulse, :boolean, default: true

  # A dot that pulses for what is going on now; it stays still for a reader who asked for less motion.
  def pulse_dot(assigns) do
    ~H"""
    <span
      data-pulse={@pulse}
      class={["shrink-0 rounded-full", @pulse && "motion-safe:animate-dot-pulse", @class]}
    ></span>
    """
  end

  attr :id, :string, default: nil
  attr :text, :string, required: true
  attr :streaming, :boolean, default: false

  @doc """
  The agent's thinking. While it streams in, it shows as it comes, after a pulsing dot; once that is over it is a
  line that opens.
  """
  def reasoning(%{streaming: true} = assigns) do
    ~H"""
    <div
      id={@id}
      data-thinking
      class="flex items-start gap-2 rounded-field border border-dashed border-line-strong px-2 py-1.5 text-xs text-fg-secondary"
    >
      <.pulse_dot class="mt-1 size-1.5 bg-dot-blue" />
      <div class="min-w-0 flex-1">
        <span class="font-medium text-base-content">Thinking</span>
        <div class="prose prose-sm max-h-52 max-w-none overflow-y-auto text-xs italic leading-[1.45] text-fg-secondary">
          {markdown(@text)}
        </div>
      </div>
    </div>
    """
  end

  def reasoning(assigns) do
    ~H"""
    <.row id={@id} text="Thought">
      <div class="prose prose-sm max-h-52 max-w-none overflow-y-auto text-xs leading-[1.45] text-fg-secondary">
        {markdown(@text)}
      </div>
    </.row>
    """
  end

  attr :id, :string, default: nil
  attr :name, :string, required: true
  attr :args, :any, default: nil

  attr :output, :string,
    default: "",
    doc: "what the tool has put out so far or, once it is done, its result"

  attr :diff, :string, default: nil, doc: "what an edit changed, shown instead of its result"
  attr :streaming, :boolean, default: false, doc: "the tool is still running"
  attr :done, :boolean, default: false, doc: "the tool has answered"
  attr :error, :boolean, default: false

  attr :duration_ms, :any,
    default: nil,
    doc: "recorded execution time, not wall-clock elapsed time"

  attr :exit_code, :integer,
    default: nil,
    doc: "what a command that has ended exited with, see `exit_code/1`"

  @doc """
  A tool call, as a box. Its header says what is called on what, the way pi does, and at the far end how it went:
  `running`, the exit code of a command, `done` or `failed`. Under it is what came out: the output, the diff of an
  edit, the content of a file that was written.
  """
  def tool(assigns) do
    call = tool_call(assigns.name, assigns.args)

    assigns =
      assign(assigns,
        call: call,
        # The header has one line; a call that takes more is shown whole under it.
        line: call |> String.split("\n", parts: 2) |> hd(),
        output: clean(assigns.output),
        written: assigns.name == "write" && is_map(assigns.args) && assigns.args["content"],
        diff: if(assigns.error, do: nil, else: assigns.diff),
        status: tool_status(assigns)
      )

    ~H"""
    <div
      id={@id}
      data-tool={@name}
      class={[
        "overflow-hidden rounded-field border bg-base-100",
        if(@error, do: "border-chip-error-line", else: "border-base-300")
      ]}
    >
      <div class="flex h-[26px] min-w-0 items-center gap-1.5 px-2 text-xs">
        <.icon name={tool_icon(@name)} class="size-3 shrink-0 text-fg-secondary" />
        <span data-tool-name class="shrink-0 font-mono">{@name}</span>
        <span
          :if={@line != ""}
          data-tool-call
          title={@call}
          class="truncate font-mono text-fg-secondary"
        >
          {@line}
        </span>
        <span class="flex-1"></span>
        <span
          :if={valid_duration?(@duration_ms)}
          id={@id && "#{@id}-duration"}
          data-tool-duration
          title="Recorded tool execution time"
          class="shrink-0 tabular-nums text-fg-secondary"
        >
          {execution_duration(@duration_ms)}
        </span>
        <span
          :if={@status}
          data-tool-status={@status.state}
          class={[
            "inline-flex shrink-0 items-center gap-[5px] text-[11px] font-medium",
            @status.color
          ]}
        >
          <.pulse_dot pulse={@status.state == "running"} class="size-[5px] bg-current" />{@status.text}
        </span>
      </div>
      <%!-- Each pre is kept on one line: inside a pre, the line breaks of the template would show. --%>
      <pre :if={@line != @call} class={[tool_pre(), wrap()]}>{@call}</pre>
      <pre :if={@written} class={[tool_pre(), wrap()]}>{truncate(@written, 8000)}</pre>
      <pre :if={@diff} data-diff class={tool_pre()}><span :for={line <- diff_lines(@diff)} class={["block min-h-[1lh]", diff_color(line.sign)]}><span data-old class="inline-block w-[5ch] select-none text-right opacity-50">{line.old}</span><span data-new class="inline-block w-[5ch] select-none text-right opacity-50">{line.new}</span><span class="inline-block w-[3ch] select-none text-center">{line.sign}</span>{line.text}</span></pre>
      <pre :if={@output != "" and !@diff} data-tool-output class={[tool_pre(), wrap()]}>{@output}</pre>
    </div>
    """
  end

  # What a tool put out: Plex Mono at 11.5px, scrolling in its own box.
  defp tool_pre,
    do:
      "m-0 max-h-60 overflow-auto border-t border-muted bg-surface-2 px-2 py-1.5 font-mono text-[11.5px] leading-[1.45] text-fg-pre"

  defp wrap, do: "whitespace-pre-wrap break-all"

  defp tool_status(%{streaming: true}),
    do: %{state: "running", text: "running", color: "text-chip-info-fg"}

  defp tool_status(%{exit_code: 0}),
    do: %{state: "ok", text: "exit 0", color: "text-chip-success-fg"}

  defp tool_status(%{exit_code: code}) when is_integer(code),
    do: %{state: "error", text: "exit #{code}", color: "text-chip-error-fg"}

  defp tool_status(%{error: true}),
    do: %{state: "error", text: "failed", color: "text-chip-error-fg"}

  defp tool_status(%{done: true}), do: %{state: "ok", text: "done", color: "text-chip-success-fg"}
  defp tool_status(_assigns), do: nil

  @doc """
  What the command of a `bash` tool result exited with: 0 when it went well, and N when pi failed it with
  "Command exited with code N", which the result carries as a diagnostic. Nothing for a command that ended some
  other way (a timeout, an abort) and for the result of any other tool.
  """
  def exit_code(nil), do: nil

  def exit_code(payload) do
    message = message(payload)

    cond do
      message["toolName"] != "bash" -> nil
      message["isError"] != true -> 0
      true -> Enum.find_value(diagnostics(payload, message), &exited_with/1)
    end
  end

  # The structured list of the entry or, without it, the block pi ends the content with for the model:
  # "<harness>\n[error] Command exited with code 2\n</harness>". The output before it is the command's own.
  defp diagnostics(payload, message) do
    case payload["data"] do
      %{"diagnostics" => [_ | _] = diagnostics} ->
        for %{"message" => text} when is_binary(text) <- diagnostics, do: text

      _ ->
        with content when is_list(content) <- message["content"],
             %{"type" => "text", "text" => "<harness>\n" <> block} <- List.last(content) do
          for line <- String.split(block, "\n"), do: String.replace(line, ~r/^\[\w+\] /, "")
        else
          _ -> []
        end
    end
  end

  defp exited_with(text) do
    case Regex.run(~r/\ACommand exited with code (-?\d+)\z/, text) do
      [_, code] -> String.to_integer(code)
      nil -> nil
    end
  end

  defp diff_color("+"), do: "text-success"
  defp diff_color("-"), do: "text-error"
  defp diff_color(_sign), do: nil

  # pi numbers each line of a diff once: an added line as it is in the new file, any other as it was in the old
  # one. This gives every line both numbers, by counting what was added and removed before it.
  defp diff_lines(diff) do
    {lines, _shift} =
      diff
      |> String.split("\n")
      |> Enum.map_reduce(0, fn line, shift ->
        case Regex.run(~r/^([+\- ])\s*(\d+) (.*)$/s, line) do
          [_, "+", number, text] ->
            {%{sign: "+", old: nil, new: number, text: text}, shift + 1}

          [_, "-", number, text] ->
            {%{sign: "-", old: number, new: nil, text: text}, shift - 1}

          [_, " ", number, text] ->
            new = String.to_integer(number) + shift
            {%{sign: nil, old: number, new: new, text: text}, shift}

          nil ->
            {%{sign: nil, old: nil, new: nil, text: String.trim(line)}, shift}
        end
      end)

    lines
  end

  # Terminal output carries color codes and carriage returns that mean nothing here.
  defp clean(output),
    do: output |> String.replace(~r/\e\[[0-9;?]*[ -\/]*[@-~]/, "") |> String.replace("\r", "")

  defp tool_icon("bash"), do: "hero-command-line-micro"
  defp tool_icon("read"), do: "hero-document-text-micro"
  defp tool_icon(name) when name in ~w(edit write), do: "hero-pencil-square-micro"
  defp tool_icon(_name), do: "hero-wrench-screwdriver-micro"

  attr :id, :string, required: true
  attr :placeholder, :string, default: nil

  attr :label, :string,
    default: nil,
    doc: "the label of the field when no header is one; it is not shown"

  attr :submit, :string, default: "Send", doc: "what the submit button says"
  attr :accent, :boolean, default: false, doc: "the submit button stands out, as for a question"
  attr :hint, :string, default: nil, doc: "a line under the field"

  attr :disabled, :boolean,
    default: false,
    doc: "there is nothing to say now, as before the agent starts"

  attr :on_stop, :any, default: nil, doc: "what the stop button does; without it there is none"

  attr :rest, :global, include: ~w(phx-submit)

  slot :header,
    doc: "what the prompt is for, as the question it answers; its label points at the field"

  slot :inner_block, doc: "hidden fields to send along"

  @doc """
  The prompt under a transcript, a bar across the page: a field that grows with what is typed, sent with Enter
  (Shift+Enter starts a new line; Escape leaves the field). While the agent works there is a button to stop it as well.
  """
  def chat_prompt(assigns) do
    ~H"""
    <form id={@id} phx-hook=".ChatPrompt" class="flex w-full flex-col gap-1.5" {@rest}>
      <div :if={@header != []} data-prompt-header>
        {render_slot(@header)}
      </div>
      {render_slot(@inner_block)}
      <div class="flex items-end gap-1.5">
        <label :if={@label} for={"#{@id}-text"} class="sr-only">{@label}</label>
        <textarea
          id={"#{@id}-text"}
          name="text"
          rows="1"
          required
          disabled={@disabled}
          placeholder={@placeholder}
          class="max-h-48 min-h-7 min-w-0 flex-1 resize-none rounded border border-line-strong bg-base-100 px-2 py-1 text-[13px] leading-[18px] text-base-content outline-none transition-colors placeholder:text-fg-tertiary focus:border-primary disabled:cursor-not-allowed disabled:opacity-60"
        ></textarea>
        <button
          :if={@on_stop}
          type="button"
          id={"#{@id}-stop"}
          phx-click={@on_stop}
          aria-label="Stop"
          class="btn btn-sm h-7 min-h-0 border-line-strong bg-base-100 px-2"
        >
          <.icon name="hero-stop-micro" class="size-4" />
        </button>
        <button
          :if={!@disabled or !@on_stop}
          type="submit"
          id={"#{@id}-submit"}
          disabled={@disabled}
          class={[
            "btn btn-sm h-7 min-h-0 px-3 text-xs font-medium",
            if(@accent, do: "btn-primary", else: "border-line-strong bg-base-100")
          ]}
        >
          {@submit}
        </button>
      </div>
      <p :if={@hint} id={"#{@id}-hint"} class="text-[11px] text-fg-secondary">{@hint}</p>
    </form>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ChatPrompt">
      export default {
        mounted() {
          this.text = this.el.querySelector("textarea")

          this.text.addEventListener("keydown", (event) => {
            if (event.key === "Escape") {
              this.text.blur()
            } else if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
              event.preventDefault()
              this.el.requestSubmit()
            }
          })

          this.text.addEventListener("input", () => this.resize())
          this.resize()

          // What was typed has been sent; the form itself stays, so the text has to be taken out.
          this.handleEvent("prompt:sent", ({id}) => {
            if (id === this.el.id) {
              this.text.value = ""
              this.resize()
            }
          })
        },

        // A patch takes the height off again.
        updated() {
          this.resize()
        },

        resize() {
          this.text.style.height = "auto"
          // The height counts the border, which the scroll height leaves out.
          const border = this.text.offsetHeight - this.text.clientHeight
          this.text.style.height = `${this.text.scrollHeight + border}px`
        }
      }
    </script>
    """
  end

  attr :item, :map, required: true

  def transcript_item(assigns) do
    assigns = assign(assigns, :context_entries, assigns.item[:context_entries] || [])

    ~H"""
    <.transcript_body item={@item} />
    <div :if={@context_entries != []} class="flex flex-wrap justify-end gap-2">
      <button
        :for={ref <- @context_entries}
        id={"inspect-#{@item.id}-#{ref.entry}"}
        type="button"
        phx-click="inspect_context"
        phx-value-conversation={ref.conversation}
        phx-value-entry={ref.entry}
        class="rounded px-1 text-[10px] text-fg-tertiary transition-colors hover:bg-base-200 hover:text-base-content"
        title="Inspect reconstructed model context through this persisted entry"
      >
        Context · {ref.kind} #{ref.entry}
      </button>
    </div>
    """
  end

  defp transcript_body(%{item: %{kind: "pi.user"}} = assigns) do
    ~H"""
    <.chat_message from="input" text={message_text(@item.payload)} first={@item[:first] == true} />
    """
  end

  defp transcript_body(%{item: %{kind: "text"}} = assigns) do
    ~H"""
    <.chat_message from="agent" text={@item.text} />
    """
  end

  defp transcript_body(%{item: %{kind: "model-timing"}} = assigns) do
    ~H"""
    <div
      id={@item.id}
      data-model-duration
      title="Recorded model response time"
      class="text-[11px] tabular-nums text-fg-tertiary"
    >
      {@item.model} · {execution_duration(@item.ms)}
    </div>
    """
  end

  # A single step needs no group around it.
  defp transcript_body(%{item: %{kind: "steps", steps: [step]}} = assigns) do
    assigns = assign(assigns, :step, step)

    ~H"""
    <.step step={@step} active={@item.active} />
    """
  end

  # The group says what was done in it, or what is being done while the agent is at work there; it stays closed.
  defp transcript_body(%{item: %{kind: "steps"}} = assigns) do
    %{steps: steps, active: active} = assigns.item
    running = active && Enum.find(Enum.reverse(steps), &(&1.type == :tool and &1.result == nil))

    assigns =
      assign(assigns,
        text: if(active, do: activity(running), else: summary(steps)),
        suffix: running && tool_call(running.name, running.args),
        note: failed(steps)
      )

    ~H"""
    <.row text={@text} suffix={@suffix || nil} note={@note} streaming={@item.active}>
      <div data-steps class="space-y-1.5">
        <.step :for={step <- @item.steps} step={step} active={@item.active} />
      </div>
    </.row>
    """
  end

  defp transcript_body(%{item: %{kind: "work"}} = assigns) do
    steps = for %{kind: "steps", steps: steps} <- assigns.item.parts, step <- steps, do: step
    assigns = assign(assigns, text: summary(steps), note: failed(steps))

    ~H"""
    <.row text={@text} note={@note} meta={@item.ms && duration(@item.ms)}>
      <div data-work class="space-y-1.5">
        <.transcript_item :for={part <- @item.parts} item={part} />
      </div>
    </.row>
    """
  end

  defp transcript_body(%{item: %{kind: "error"}} = assigns) do
    ~H"""
    <div data-error class="text-xs text-chip-error-fg">{@item.text}</div>
    """
  end

  defp transcript_body(%{item: %{kind: "pi.tool-result"}} = assigns) do
    ~H"""
    <.tool
      name={"#{message(@item.payload)["toolName"]} result"}
      output={result_text(@item.payload)}
      error={result_error?(@item.payload)}
      exit_code={exit_code(@item.payload)}
      duration_ms={message(@item.payload)["durationMs"]}
      done
    />
    """
  end

  # A note says what Conductor did; what it has to show for it (as the output of the setup) opens under the line.
  defp transcript_body(%{item: %{kind: "conductor.note"}} = assigns) do
    ~H"""
    <.rule :if={@item.payload["text"] in [nil, ""]} text={@item.payload["title"]} />
    <details :if={@item.payload["text"] not in [nil, ""]} data-note>
      <summary class="cursor-pointer list-none rounded-field transition-colors hover:text-base-content [&::-webkit-details-marker]:hidden">
        <.rule text={@item.payload["title"]} />
      </summary>
      <pre class={[tool_pre(), wrap(), "mt-1.5 max-h-96! rounded-field border border-base-300!"]}>{truncate(@item.payload["text"], 8000)}</pre>
    </details>
    """
  end

  defp transcript_body(%{item: %{kind: "pi.compaction"}} = assigns) do
    ~H"""
    <.rule text="context compacted" />
    """
  end

  defp transcript_body(assigns) do
    ~H"""
    <div class="text-[11px] text-fg-tertiary">{@item.kind}</div>
    """
  end

  attr :text, :string, required: true

  # Something that happened between the messages: a centred line with a rule on both sides.
  defp rule(assigns) do
    ~H"""
    <div
      data-rule
      class="divider m-0 h-auto gap-2 text-[11px] text-fg-tertiary before:h-px before:bg-base-300 after:h-px after:bg-base-300"
    >
      {@text}
    </div>
    """
  end

  attr :step, :map, required: true

  attr :active, :boolean,
    default: false,
    doc: "the agent is at work here: a call without a result is running"

  defp step(%{step: %{type: :thinking}} = assigns) do
    ~H"""
    <.reasoning text={@step.text} />
    """
  end

  defp step(%{step: %{type: :tool}} = assigns) do
    ~H"""
    <.tool
      id={"tool-#{@step.id}"}
      name={@step.name}
      args={@step.args}
      output={result_text(@step.result)}
      diff={@step.result && message(@step.result)["details"]["diff"]}
      error={result_error?(@step.result)}
      exit_code={exit_code(@step.result)}
      duration_ms={@step.result && message(@step.result)["durationMs"]}
      done={@step.result != nil}
      streaming={@active and @step.result == nil}
    />
    """
  end

  defp failed(steps) do
    case Enum.count(steps, &(&1.type == :tool and result_error?(&1.result))) do
      0 -> nil
      count -> "#{count} failed"
    end
  end

  defp valid_duration?(ms), do: is_number(ms) and ms >= 0

  defp execution_duration(ms) when ms < 1000, do: "#{round(ms)}ms"
  defp execution_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp execution_duration(ms), do: duration(round(ms))

  defp duration(ms) when ms < 60_000, do: "#{max(div(ms, 1000), 1)}s"
  defp duration(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)}m #{rem(div(ms, 1000), 60)}s"
  defp duration(ms), do: "#{div(ms, 3_600_000)}h #{rem(div(ms, 60_000), 60)}m"

  # What was done in a group of steps, in the order it was first done: "Thought, read 4 files, ran 2 commands".
  defp summary(steps) do
    thought = if Enum.any?(steps, &(&1.type == :thinking)), do: ["thought"], else: []
    tools = for %{type: :tool} = step <- steps, do: {done(step.name), step}

    done =
      for kind <- tools |> Enum.map(&elem(&1, 0)) |> Enum.uniq() do
        counted(kind, for({^kind, step} <- tools, do: step))
      end

    case thought ++ done do
      [] -> "Worked"
      [first | rest] -> Enum.join([String.capitalize(first) | rest], ", ")
    end
  end

  defp done("bash"), do: :ran
  defp done("read"), do: :read
  defp done(name) when name in ~w(edit write), do: :edited
  defp done("set_issue_status"), do: :status
  defp done("run_subagents"), do: :subagents
  defp done(_name), do: :used

  defp counted(:ran, steps), do: "ran #{count(length(steps), "command")}"
  defp counted(:read, steps), do: "read #{count(files(steps), "file")}"
  defp counted(:edited, steps), do: "edited #{count(files(steps), "file")}"
  defp counted(:status, _steps), do: "updated the issue status"
  defp counted(:subagents, _steps), do: "ran subagents"
  defp counted(:used, steps), do: "used #{count(length(steps), "tool")}"

  # A file that was read twice is one file.
  defp files(steps) do
    steps
    |> Enum.uniq_by(fn step -> (is_map(step.args) && step.args["path"]) || step.id end)
    |> length()
  end

  defp count(1, noun), do: "1 #{noun}"
  defp count(number, noun), do: "#{number} #{noun}s"

  defp activity(%{name: "bash"}), do: "Running commands"
  defp activity(%{name: "read"}), do: "Reading files"
  defp activity(%{name: name}) when name in ~w(edit write), do: "Editing files"
  defp activity(%{name: "set_issue_status"}), do: "Updating the issue status"
  defp activity(%{name: "run_subagents"}), do: "Running subagents"
  defp activity(%{name: name}), do: "Using #{name}"
  defp activity(_none), do: "Working"

  defp result_text(nil), do: ""
  defp result_text(payload), do: truncate(message_text(payload), 8000)

  defp result_error?(nil), do: false
  defp result_error?(payload), do: message(payload)["isError"] == true

  @doc """
  Whether the agent is at work after this item: it was just told something, a tool it called answered, or it
  stopped to call one.
  """
  def awaiting?(%{kind: kind}) when kind in ~w(pi.user pi.tool-result), do: true

  def awaiting?(%{kind: "pi.assistant", payload: payload}),
    do: message(payload)["stopReason"] == "toolUse"

  def awaiting?(_item), do: false

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

  @doc "What a tool is called on, in one line: the command, the file and the lines read from it, and so on."
  def tool_call("read", %{"path" => path} = args) do
    case {args["offset"], args["limit"]} do
      {nil, nil} -> path
      {offset, nil} -> "#{path}:#{offset}-"
      {offset, limit} -> "#{path}:#{offset || 1}-#{(offset || 1) + limit - 1}"
    end
  end

  def tool_call("set_issue_status", %{"number" => number, "status" => status}),
    do: "##{number} → #{status}"

  def tool_call("run_subagents", %{"tasks" => tasks}) when is_list(tasks),
    do: "#{length(tasks)} #{if length(tasks) == 1, do: "task", else: "tasks"}"

  def tool_call(_name, %{"command" => command}), do: command
  def tool_call(_name, %{"path" => path}), do: path
  def tool_call(_name, args) when is_map(args) and args != %{}, do: Jason.encode!(args)
  def tool_call(_name, _args), do: ""

  def truncate(nil, _), do: ""
  def truncate(text, max) when byte_size(text) <= max, do: text
  def truncate(text, max), do: binary_part(text, 0, max) <> "\n… (truncated)"
end
