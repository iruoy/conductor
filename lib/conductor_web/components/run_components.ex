defmodule ConductorWeb.RunComponents do
  @moduledoc "Pieces shared by the run pages: status badges and transcript items."
  use Phoenix.Component
  import ConductorWeb.CoreComponents, only: [icon: 1]

  attr :status, :atom, required: true

  def status_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm whitespace-nowrap", badge_class(@status)]}>
      {String.replace(to_string(@status), "_", " ")}
    </span>
    """
  end

  defp badge_class(:completed), do: "badge-success"
  defp badge_class(:failed), do: "badge-error"
  defp badge_class(:waiting_for_input), do: "badge-warning"
  defp badge_class(status) when status in ~w(running provisioning handing_off)a, do: "badge-info"
  defp badge_class(_), do: "badge-ghost"

  @doc "The DOM id of a persisted or live transcript item."
  def item_dom_id(conversation, entry),
    do: "ev-#{conversation}-#{String.replace(entry, ~r/[^A-Za-z0-9_-]/, "-")}"

  @doc "Turns a persisted `Conductor.Runs.Event` into a transcript item."
  def item(%Conductor.Runs.Event{} = event) do
    %{id: item_dom_id(event.conversation, event.entry), kind: event.kind, payload: event.payload}
  end

  @doc "Turns a live `message_end` entry into a transcript item."
  def item(conversation, %{"id" => id, "kind" => kind} = entry) do
    %{id: item_dom_id(conversation, "e:#{id}"), kind: kind, payload: entry}
  end

  @doc """
  What a list of transcript items shows: the agent's texts and, between them, what it did to get there. Its
  thinking and its tool calls are steps; the steps between two texts make one group (kind `steps`), also when
  they come from several messages, and each tool result goes onto its call.
  """
  def transcript(items), do: items |> unfolded() |> fold_turns()

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
  def parts(%{kind: "pi.assistant", id: id, payload: payload}) do
    message = message(payload)

    parts =
      (message["content"] || [])
      |> Enum.with_index()
      |> Enum.flat_map(fn {block, index} -> part("#{id}-#{index}", block) end)
      |> join_steps()

    case stop_notice(message) do
      nil -> answer(parts, message)
      notice -> parts ++ [%{id: "#{id}-error", kind: "error", text: notice}]
    end
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
  def add_steps(group, %{kind: "steps", steps: steps}),
    do: %{group | steps: Enum.reduce(steps, group.steps, &add_step(&2, &1))}

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

    %{group | steps: steps}
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

  @doc """
  A message of the conversation: what the agent was told (`input`), in a soft box at the far side, or what it says
  (`agent`), as plain text across the width.
  """
  def chat_message(%{from: "input"} = assigns) do
    ~H"""
    <article data-from="input" class="flex justify-end py-2">
      <span class="sr-only">Input</span>
      <div class="max-w-[82%] rounded-2xl bg-base-200 px-4 py-2.5">
        <div class="prose prose-sm">{markdown(@text)}</div>
      </div>
    </article>
    """
  end

  def chat_message(assigns) do
    ~H"""
    <article data-from="agent">
      <span class="sr-only">Agent</span>
      <div class="prose prose-sm max-w-none">{markdown(@text)}</div>
    </article>
    """
  end

  attr :id, :string, default: nil
  attr :icon, :string, required: true
  attr :text, :string, required: true

  attr :suffix, :string,
    default: nil,
    doc: "secondary text after the label, as the command of a tool call"

  attr :note, :any, default: nil, doc: "a remark after the label, as what is kept inside"
  attr :streaming, :boolean, default: false, doc: "still going on: the label shimmers"
  attr :open, :boolean, default: false
  attr :error, :boolean, default: false
  slot :inner_block

  @doc """
  A line of the transcript for what the agent does besides talking: a tool call, its thinking, a note. With
  content it opens to show it; its icon then makes way for a chevron.
  """
  def row(%{inner_block: []} = assigns) do
    ~H"""
    <div id={@id} class={["flex min-w-0 items-center gap-1.5 text-sm", row_color(@error)]}>
      <.icon name={@icon} class="size-4 shrink-0" />
      <.row_label text={@text} suffix={@suffix} note={@note} streaming={@streaming} />
    </div>
    """
  end

  def row(assigns) do
    ~H"""
    <details id={@id} open={@open}>
      <summary class={[
        "group/trigger flex min-w-0 cursor-pointer list-none items-center gap-1.5 rounded-sm text-sm",
        "transition-colors hover:text-base-content [&::-webkit-details-marker]:hidden",
        row_color(@error)
      ]}>
        <span class="relative size-4 shrink-0">
          <.icon
            name={@icon}
            class="absolute inset-0 size-4 transition-opacity duration-200 [details[open]>summary_&]:opacity-0 group-hover/trigger:opacity-0"
          />
          <.icon
            name="hero-chevron-down-micro"
            class="absolute inset-0 size-4 opacity-0 transition-[rotate,opacity] duration-200 [details[open]>summary_&]:rotate-180 [details[open]>summary_&]:opacity-100 group-hover/trigger:opacity-100 motion-reduce:transition-none"
          />
        </span>
        <.row_label text={@text} suffix={@suffix} note={@note} streaming={@streaming} />
      </summary>
      <div class="pt-2 text-sm text-base-content/60">{render_slot(@inner_block)}</div>
    </details>
    """
  end

  attr :text, :string, required: true
  attr :suffix, :string, default: nil
  attr :note, :any, default: nil
  attr :streaming, :boolean, default: false

  defp row_label(assigns) do
    ~H"""
    <span class="truncate">
      <span class={@streaming && "skeleton skeleton-text"}>{@text}</span>
      <span :if={@suffix not in [nil, ""]} class="ms-1 font-mono text-xs opacity-70">{@suffix}</span>
      <span :if={@note not in [nil, false, ""]} class="opacity-70">{@note}</span>
    </span>
    """
  end

  defp row_color(true), do: "text-error"
  defp row_color(false), do: "text-base-content/60"

  attr :id, :string, default: nil
  attr :text, :string, required: true
  attr :streaming, :boolean, default: false

  @doc "The agent's thinking. It is open for as long as the thinking streams in and closes once that is over."
  def reasoning(assigns) do
    ~H"""
    <.row
      id={@id}
      icon="hero-light-bulb-micro"
      text={if @streaming, do: "Thinking…", else: "Thought"}
      streaming={@streaming}
      open={@streaming}
    >
      <div class="prose prose-sm max-h-52 max-w-none overflow-y-auto text-base-content/60">
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
  attr :error, :boolean, default: false

  @doc """
  A tool call. Its line says what is called on what, the way pi does; it opens to show the whole call and what
  came out of it: the output, the diff of an edit, the content of a file that was written.
  """
  def tool(assigns) do
    assigns =
      assign(assigns,
        call: tool_call(assigns.name, assigns.args),
        output: clean(assigns.output),
        written: assigns.name == "write" && is_map(assigns.args) && assigns.args["content"],
        diff: if(assigns.error, do: nil, else: assigns.diff)
      )

    ~H"""
    <.row
      :if={@call == "" and @output == ""}
      id={@id}
      icon={tool_icon(@name)}
      text={@name}
      streaming={@streaming}
      error={@error}
    />
    <.row
      :if={@call != "" or @output != ""}
      id={@id}
      icon={tool_icon(@name)}
      text={@name}
      suffix={@call}
      streaming={@streaming}
      open={@streaming and @output != ""}
      error={@error}
    >
      <div class="divide-y divide-base-300 rounded-box bg-base-200/60 px-3 font-mono text-xs *:py-2">
        <pre :if={@call != ""} class="whitespace-pre-wrap break-all text-base-content/80">{@call}</pre>
        <pre :if={@written} class="max-h-60 overflow-auto whitespace-pre-wrap break-all">{truncate(@written, 8000)}</pre>
        <%!-- Kept on one line: inside a pre, the line breaks of the template would show between the lines. --%>
        <pre :if={@diff} data-diff class="max-h-60 overflow-auto"><span :for={line <- diff_lines(@diff)} class={["block min-h-[1lh]", diff_color(line.sign)]}><span data-old class="inline-block w-[5ch] select-none text-right opacity-50">{line.old}</span><span data-new class="inline-block w-[5ch] select-none text-right opacity-50">{line.new}</span><span class="inline-block w-[3ch] select-none text-center">{line.sign}</span>{line.text}</span></pre>
        <pre
          :if={@output != "" and !@diff}
          class="max-h-60 overflow-auto whitespace-pre-wrap break-all"
        >{@output}</pre>
      </div>
    </.row>
    """
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

  attr :disabled, :boolean,
    default: false,
    doc: "there is nothing to say now, as before the agent starts"

  attr :on_stop, :any, default: nil, doc: "what the stop button does; without it there is none"

  attr :rest, :global, include: ~w(phx-submit)
  slot :header, doc: "what the prompt is for, as the question it answers"
  slot :inner_block, doc: "hidden fields to send along"

  @doc """
  The prompt under a transcript: a text that grows with what is typed, sent with Enter (Shift+Enter starts a new
  line; Escape leaves the field). While the agent works there is a button to stop it as well.
  """
  def chat_prompt(assigns) do
    ~H"""
    <form
      id={@id}
      phx-hook=".ChatPrompt"
      class="mx-auto flex w-full max-w-4xl flex-col gap-2 rounded-2xl border border-base-300 bg-base-100 px-2.5 py-2 transition-colors has-[textarea:focus-visible]:border-primary"
      {@rest}
    >
      <div :if={@header != []} data-prompt-header class="px-1.5 pt-1 text-sm">
        {render_slot(@header)}
      </div>
      {render_slot(@inner_block)}
      <textarea
        id={"#{@id}-text"}
        name="text"
        rows="1"
        required
        disabled={@disabled}
        placeholder={@placeholder}
        aria-label={@placeholder}
        class="textarea textarea-ghost max-h-48 min-h-0 w-full resize-none px-1.5 py-1 focus:bg-transparent focus:outline-none disabled:bg-transparent"
      ></textarea>
      <div class="flex items-center justify-end gap-1.5">
        <button
          :if={@on_stop}
          type="button"
          id={"#{@id}-stop"}
          phx-click={@on_stop}
          aria-label="Stop"
          class="btn btn-circle btn-soft btn-sm"
        >
          <.icon name="hero-stop-micro" class="size-4" />
        </button>
        <button
          :if={!@disabled or !@on_stop}
          type="submit"
          id={"#{@id}-submit"}
          disabled={@disabled}
          aria-label="Send"
          class="btn btn-circle btn-primary btn-sm"
        >
          <.icon name="hero-arrow-up-micro" class="size-4" />
        </button>
      </div>
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

  def transcript_item(%{item: %{kind: "pi.user"}} = assigns) do
    ~H"""
    <.chat_message from="input" text={message_text(@item.payload)} />
    """
  end

  def transcript_item(%{item: %{kind: "text"}} = assigns) do
    ~H"""
    <.chat_message from="agent" text={@item.text} />
    """
  end

  # A single step needs no group around it.
  def transcript_item(%{item: %{kind: "steps", steps: [step]}} = assigns) do
    assigns = assign(assigns, :step, step)

    ~H"""
    <.step step={@step} active={@item.active} />
    """
  end

  # The group says what was done in it, or what is being done while the agent is at work there; it stays closed.
  def transcript_item(%{item: %{kind: "steps"}} = assigns) do
    %{steps: steps, active: active} = assigns.item
    failed = Enum.count(steps, &(&1.type == :tool and result_error?(&1.result)))
    running = active && Enum.find(Enum.reverse(steps), &(&1.type == :tool and &1.result == nil))

    assigns =
      assign(assigns,
        text: if(active, do: activity(running), else: summary(steps)),
        suffix: running && tool_call(running.name, running.args),
        note:
          Enum.join(
            ["· #{length(steps)} steps"] ++ if(failed > 0, do: ["· #{failed} failed"], else: []),
            " "
          )
      )

    ~H"""
    <.row
      icon="hero-queue-list-micro"
      text={@text}
      suffix={@suffix || nil}
      note={@note}
      streaming={@item.active}
    >
      <div data-steps class="space-y-1.5 border-s border-base-300 ps-3">
        <.step :for={step <- @item.steps} step={step} active={@item.active} />
      </div>
    </.row>
    """
  end

  def transcript_item(%{item: %{kind: "work"}} = assigns) do
    steps = for %{kind: "steps", steps: steps} <- assigns.item.parts, step <- steps, do: step
    failed = Enum.count(steps, &(&1.type == :tool and result_error?(&1.result)))

    note =
      ["· #{length(steps)} steps"] ++ if(failed > 0, do: ["· #{failed} failed"], else: [])

    assigns = assign(assigns, note: Enum.join(note, " "))

    ~H"""
    <.row
      icon="hero-check-circle-micro"
      text={if @item.ms, do: "Worked for #{duration(@item.ms)}", else: "Worked"}
      note={@note}
    >
      <div data-work class="space-y-4 border-s border-base-300 ps-3">
        <.transcript_item :for={part <- @item.parts} item={part} />
      </div>
    </.row>
    """
  end

  def transcript_item(%{item: %{kind: "error"}} = assigns) do
    ~H"""
    <div class="text-sm text-error">{@item.text}</div>
    """
  end

  def transcript_item(%{item: %{kind: "pi.tool-result"}} = assigns) do
    ~H"""
    <.tool
      name={"#{message(@item.payload)["toolName"]} result"}
      output={result_text(@item.payload)}
      error={result_error?(@item.payload)}
    />
    """
  end

  def transcript_item(%{item: %{kind: "conductor.note"}} = assigns) do
    ~H"""
    <.row icon="hero-information-circle-micro" text={@item.payload["title"]}>
      <pre class="max-h-96 overflow-auto whitespace-pre-wrap rounded-box bg-base-200/60 p-3 font-mono text-xs">{truncate(@item.payload["text"], 8000)}</pre>
    </.row>
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
      name={@step.name}
      args={@step.args}
      output={result_text(@step.result)}
      diff={@step.result && message(@step.result)["details"]["diff"]}
      error={result_error?(@step.result)}
      streaming={@active and @step.result == nil}
    />
    """
  end

  defp duration(ms) when ms < 60_000, do: "#{max(div(ms, 1000), 1)}s"
  defp duration(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)}m #{rem(div(ms, 1000), 60)}s"
  defp duration(ms), do: "#{div(ms, 3_600_000)}h #{rem(div(ms, 60_000), 60)}m"

  # What a group of steps was for: its most frequent kinds of tool call.
  defp summary(steps) do
    kinds =
      for(%{type: :tool, name: name} <- steps, do: done(name))
      |> Enum.frequencies()
      |> Enum.sort_by(fn {kind, count} -> {-count, kind} end)
      |> Enum.take(3)
      |> Enum.map(&elem(&1, 0))

    if kinds == [], do: "Thought", else: kinds |> Enum.join(", ") |> String.capitalize()
  end

  defp done("bash"), do: "ran commands"
  defp done("read"), do: "read files"
  defp done(name) when name in ~w(edit write), do: "edited files"
  defp done("set_issue_status"), do: "updated the issue status"
  defp done("run_subagents"), do: "ran subagents"
  defp done(_name), do: "used tools"

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
