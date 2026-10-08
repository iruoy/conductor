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
     |> assign(
       page_title: run.id,
       run: run,
       conversations: conversations,
       retryable?: Runs.retryable?(run)
     )
     |> assign(attempts: Runs.other_attempts(run), history: Runs.status_history(id))
     |> assign(inbox: [], sent: %{}, models: Runs.conversation_models(id))
     |> assign(ends: Runs.conversation_ends(id))
     |> assign_questions()
     |> select(default_conversation(conversations))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_page={:runs} waiting_count={@waiting_count}>
      <%!-- From `lg` up the page fills the window below the app header (2.5rem and its border): only the
      transcript scrolls, and the header strip, tabs, details and prompt stay in view. On a narrower window the
      details come under the transcript and the page scrolls as a whole. --%>
      <div
        id="run"
        class="flex min-h-[calc(100dvh-2.5rem-1px)] flex-col lg:h-[calc(100dvh-2.5rem-1px)]"
      >
        <.run_header run={@run} retryable?={@retryable?} />
        <.error_banner :if={@run.status == :failed && @run.error} error={@run.error} />

        <div
          :if={@conversations != []}
          role="tablist"
          aria-label="Conversations"
          class="tabs tabs-border shrink-0 flex-nowrap overflow-x-auto border-b border-base-300 bg-base-100 px-3"
          id="conversations"
        >
          <button
            :for={{conversation, label, state} <- tabs(@run, @conversations, @ends)}
            role="tab"
            id={"tab-#{conversation}"}
            data-state={state}
            aria-selected={to_string(@selected == conversation)}
            title={tab_title(state, @conversations, conversation, @models)}
            phx-click="select"
            phx-value-conversation={conversation}
            class={[
              "tab h-[30px] gap-1.5 px-2.5 text-xs text-fg-secondary",
              "before:!left-0 before:!h-0.5 before:!w-full before:!rounded-none",
              @selected == conversation &&
                "tab-active !text-base-content [--tab-border-color:var(--link)]"
            ]}
          >
            <.pulse_dot pulse={state == "working"} class={["size-1.5", state_dot(state)]} />
            {label}
          </button>
        </div>

        <div class="flex min-h-0 flex-1 flex-col lg:flex-row">
          <%!-- The scroller centres its content with room for a wide page; here it starts at the left, as wide as
        the design's transcript column. --%>
          <.message_scroller
            id="transcript-scroller"
            key={@selected}
            class="min-h-80 min-w-0 flex-[1_1_60dvh] lg:min-h-0 lg:flex-1 [&_[data-scroller-content]]:mx-0 [&_[data-scroller-content]]:max-w-[856px] [&_[data-scroller-viewport]]:px-3 [&_[data-scroller-viewport]]:py-2.5"
          >
            <div id="transcript" phx-update="stream" class="space-y-1.5">
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

            <.failed_line
              :if={@run.status == :failed and head?(@conversations, @selected)}
              at={failed_at(@history, @run)}
            />

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
          <.sidebar
            run={@run}
            attempts={@attempts}
            history={@history}
            head={head?(@conversations, @selected)}
            model={model(@run, @conversations, @selected, @models)}
          />
        </div>

        <%!-- The oldest open question is answered here. Without one, what is typed goes to the head agent while it
        works; it waits in the agent's inbox until the tools that are running are done. --%>
        <div
          :if={@open_questions != [] or @run.status == :completed or not Run.terminal?(@run)}
          id="prompt-bar"
          class={[
            "shrink-0 border-t border-base-300 px-3 py-2",
            if(@open_questions != [],
              do: "bg-row-waiting shadow-[inset_0_2px_0_var(--dot-orange)]",
              else: "bg-base-100"
            )
          ]}
        >
          <%= case @open_questions do %>
            <% [q | more] -> %>
              <.chat_prompt
                id={"answer-#{q.qid}"}
                phx-submit="answer"
                placeholder="Your answer"
                submit="Answer"
                accent
              >
                <:header>
                  <div id={"question-#{q.qid}"} class="flex items-start gap-1.5">
                    <.icon
                      name="hero-chat-bubble-left-ellipsis-micro"
                      class="mt-px size-4 shrink-0 text-warning"
                    />
                    <div class="min-w-0">
                      <div class="text-[11px] font-medium text-chip-warning-fg">
                        The agent asks
                        <span class="font-normal text-fg-secondary">
                          · {local_time(q.inserted_at)}
                        </span>
                        <span
                          :if={more != []}
                          id="questions-more"
                          class="font-normal text-fg-secondary"
                        >
                          · {length(more)} more after this
                        </span>
                      </div>
                      <%!-- pre-wrap keeps the question's line breaks, so no whitespace around the text --%>
                      <label
                        for={"answer-#{q.qid}-text"}
                        class="block max-h-40 overflow-y-auto whitespace-pre-wrap"
                        phx-no-format
                      >{q.text}</label>
                    </div>
                  </div>
                </:header>
                <input type="hidden" name="qid" value={q.qid} />
              </.chat_prompt>
            <% [] -> %>
              <.chat_prompt
                :if={@run.status == :completed or not Run.terminal?(@run)}
                id="prompt"
                phx-submit="message"
                label="Message the head agent"
                placeholder={prompt_placeholder(@run.status, head?(@conversations, @selected))}
                hint={
                  if(@run.status == :completed,
                    do: "Continues this conversation and updates the same pull request.",
                    else: "Waits in the agent's inbox until the tools that are running are done."
                  )
                }
                on_stop={abortable?(@run) && show_modal("confirm-abort")}
                disabled={@run.status not in [:running, :completed]}
              >
                <:header :if={@inbox != []}>
                  <ul id="inbox" class="space-y-1">
                    <li
                      :for={%{"id" => id} <- @inbox}
                      id={"inbox-#{id}"}
                      class="flex items-center gap-2 text-fg-secondary"
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
      </div>
    </Layouts.app>
    """
  end

  attr :run, Run, required: true

  attr :retryable?, :boolean, required: true

  # The strip under the app header: where the run is, what it is and how it stands, and what can be done with it.
  defp run_header(assigns) do
    assigns = assign(assigns, snapshot: assigns.run.issue_snapshot || %{})

    ~H"""
    <section
      id="run-header"
      class="flex shrink-0 flex-wrap items-center gap-3 border-b border-base-300 bg-base-100 px-3 py-2"
    >
      <div class="flex min-w-0 flex-[1_1_480px] flex-col gap-[3px]">
        <div class="flex min-w-0 items-baseline gap-1.5">
          <.link
            navigate={~p"/"}
            id="run-back"
            class="text-xs text-fg-secondary transition-colors hover:text-link-hover hover:underline"
          >
            Runs
          </.link>
          <span class="text-fg-faint" aria-hidden="true">/</span>
          <h1 id="run-title" class="truncate text-sm font-semibold" title={@snapshot["summary"]}>
            <span id="run-id" class="font-mono font-medium">{@run.id}</span>
            <span :if={@snapshot["summary"]} id="run-summary">· {@snapshot["summary"]}</span>
          </h1>
        </div>
        <div class="flex flex-wrap items-center gap-2 text-xs text-fg-secondary">
          <.status_badge id="run-status" status={@run.status} />
          <span :if={@run.branch} id="run-branch" class="inline-flex items-center gap-1 font-mono">
            <.icon name="hero-share-micro" class="size-3" />
            {@run.branch}
          </span>
          <span id="run-started">{started(@run)}</span>
        </div>
      </div>
      <div class="flex gap-1">
        <a
          :if={@snapshot["url"]}
          id="open-issue"
          href={@snapshot["url"]}
          target="_blank"
          rel="noopener"
          class="btn btn-sm h-7 min-h-0 border-line-strong bg-base-100 px-2.5 text-xs font-medium"
        >
          Open issue
        </a>
        <button
          :if={@retryable?}
          id="retry"
          phx-click="retry"
          class="btn btn-sm btn-primary h-7 min-h-0 px-2.5 text-xs font-medium"
        >
          Retry
        </button>
        <button
          :if={abortable?(@run)}
          id="abort"
          phx-click={show_modal("confirm-abort")}
          class="btn btn-sm h-7 min-h-0 border-chip-error-line bg-base-100 px-2.5 text-xs font-medium text-chip-error-fg"
        >
          Abort
        </button>
        <.confirm_modal
          :if={abortable?(@run)}
          id="confirm-abort"
          title="Abort this run?"
          confirm="Abort"
          on_confirm={JS.push("abort")}
        >
          The agent stops and the run is marked as failed.
        </.confirm_modal>
      </div>
    </section>
    """
  end

  attr :error, :string, required: true

  # Why a failed run failed, as it was reported: line breaks kept.
  defp error_banner(assigns) do
    ~H"""
    <div
      id="run-error"
      role="alert"
      class="flex shrink-0 items-start gap-2 border-b border-chip-error-line bg-chip-error-bg px-3 py-2 text-xs text-chip-error-fg"
    >
      <.icon name="hero-exclamation-triangle-micro" class="mt-px size-3.5 shrink-0" />
      <span
        id="run-error-text"
        class="max-h-40 min-w-0 overflow-y-auto whitespace-pre-wrap break-words font-mono"
      >{@error}</span>
    </div>
    """
  end

  attr :run, Run, required: true
  attr :attempts, :list, required: true, doc: "the other runs of the same issue"

  attr :history, :list,
    required: true,
    doc: "the statuses the run has had, see `Runs.status_history/1`"

  attr :head, :boolean,
    required: true,
    doc: "whether the conversation on show is the head agent's"

  attr :model, :map, required: true, doc: "the model choice of the conversation on show, or nil"

  # What the run belongs to and where its work is, and how it got to where it stands. `#run-details` is a list of
  # `dt`/`dd` pairs; further blocks follow it in the `aside`, each after a rule.
  defp sidebar(assigns) do
    ~H"""
    <aside
      id="run-sidebar"
      aria-label="Run details"
      class="flex shrink-0 flex-col gap-2.5 border-t border-base-300 bg-base-100 px-3 py-2.5 text-xs lg:w-[280px] lg:overflow-y-auto lg:border-l lg:border-t-0"
    >
      <dl id="run-details" class="grid grid-cols-[84px_minmax(0,1fr)] gap-x-2 gap-y-1">
        <dt class="text-fg-secondary">Project</dt>
        <dd id="run-project">
          {if @run.project,
            do: "#{@run.project.project_owner}/#{@run.project.project_number}",
            else: "—"}
        </dd>

        <dt class="text-fg-secondary">Repository</dt>
        <dd id="run-repository" class="break-all font-mono">
          {(@run.project && @run.project.repo && @run.project.repo.name) || "—"}
        </dd>

        <dt id="run-model-label" class="text-fg-secondary">
          {if @head, do: "Head model", else: "Model"}
        </dt>
        <dd id="run-model" class="min-w-0">
          <span :if={@model} id="run-model-id" class="break-all font-mono">{model_id(@model)}</span>
          <span :if={@model && @model["reasoning"]} id="run-model-reasoning" class="text-fg-secondary">
            · {@model["reasoning"]}
          </span>
          <span :if={!@model} class="text-fg-secondary">
            {if @head or Run.terminal?(@run), do: "Not recorded", else: "Not known yet"}
          </span>
        </dd>

        <dt class="text-fg-secondary">Pull request</dt>
        <dd id="run-pr" class="min-w-0">
          <a
            :if={@run.pr_url}
            id="run-pr-link"
            href={@run.pr_url}
            target="_blank"
            rel="noopener"
            class="break-all text-link transition-colors hover:text-link-hover hover:underline"
          >
            {pr_label(@run.pr_url)}
          </a>
          <span :if={!@run.pr_url} class="text-fg-secondary">Not opened yet</span>
        </dd>

        <dt class="text-fg-secondary">Attempt</dt>
        <dd id="run-attempts" class="flex min-w-0 flex-col gap-0.5">
          <span id="run-attempt">{@run.attempt}</span>
          <span :for={other <- @attempts} id={"attempt-#{other.id}"} class="flex items-center gap-1.5">
            <.link
              navigate={~p"/runs/#{other.id}"}
              class="truncate font-mono text-link transition-colors hover:text-link-hover hover:underline"
            >
              {other.id}
            </.link>
            <span
              data-status={other.status}
              class={["shrink-0 text-[11px]", status_text(other.status)]}
            >
              {status_label(other.status)}
            </span>
          </span>
        </dd>

        <dt class="text-fg-secondary">Workspace</dt>
        <dd id="run-workspace" class="min-w-0">
          <span :if={@run.workspace_path} class="break-all font-mono">{@run.workspace_path}</span>
          <span :if={!@run.workspace_path} class="text-fg-secondary">
            {if Run.terminal?(@run), do: "Removed", else: "Not created yet"}
          </span>
        </dd>
      </dl>
      <.timeline :if={@history != []} history={@history} />
      <.classification_audit run={@run} />
    </aside>
    """
  end

  attr :run, Run, required: true

  defp classification_audit(assigns) do
    snapshot = assigns.run.issue_snapshot || %{}
    issues = [snapshot | snapshot["subtasks"] || []]

    rows =
      Enum.map(issues, fn issue ->
        key = issue["key"] || assigns.run.issue_key
        tier = if issue == snapshot, do: "head", else: Conductor.Prompt.complexity(issue)
        models = assigns.run.models || %{}
        chosen = models[tier] || models["high"] || models["head"]
        audit = (assigns.run.classifications || %{})[key]
        suggested = if audit, do: models[audit["complexity"]] || models["head"]
        %{key: key, tier: tier, chosen: chosen, audit: audit, suggested: suggested}
      end)

    assigns = assign(assigns, :rows, rows)

    ~H"""
    <section id="classification-audit" class="border-t border-base-300 pt-2.5">
      <h2 class="text-fg-secondary">Size audit · shadow mode</h2>
      <p class="mt-1 text-fg-secondary">Suggestions do not change routing.</p>
      <div :for={row <- @rows} data-issue-key={row.key} class="mt-2 space-y-1">
        <h3 class="font-mono">{row.key}</h3>
        <p>
          Chosen routing: {row.tier} · {if row.chosen, do: model_id(row.chosen), else: "Not recorded"}
        </p>
        <%= if row.audit do %>
          <p>{row.audit["status"]} · {row.audit["complexity"]}</p>
          <p :if={row.audit["status"] == "suggested"}>
            Suggested routing: {row.audit["complexity"]} · {if row.suggested,
              do: model_id(row.suggested),
              else: "Not configured"}
          </p>
          <p class="break-words text-fg-secondary">{row.audit["reason"]}</p>
          <p class="break-all text-fg-secondary">
            {row.audit["provider"] || "—"}/{row.audit["model"] || "—"} · {row.audit["latency_ms"]} ms
          </p>
        <% else %>
          <p class="text-fg-secondary">Not recorded</p>
        <% end %>
      </div>
    </section>
    """
  end

  attr :history, :list, required: true

  # The statuses the run has had, the first first. A run from before they were kept has none, and no timeline.
  defp timeline(assigns) do
    ~H"""
    <div class="h-px bg-muted"></div>
    <section id="run-timeline" aria-labelledby="run-timeline-title" class="flex flex-col gap-[3px]">
      <h2
        id="run-timeline-title"
        class="text-[11px] font-normal uppercase tracking-[0.04em] text-fg-secondary"
      >
        Timeline
      </h2>
      <ol id="run-timeline-entries" class="flex flex-col gap-[3px]">
        <li
          :for={entry <- @history}
          id={"timeline-#{entry.id}"}
          data-status={entry.status}
          class="flex items-center gap-2"
        >
          <span class={["size-1.5 shrink-0 rounded-full", status_dot(entry.status)]}></span>
          <span class="min-w-0 flex-1">{status_label(entry.status)}</span>
          <time datetime={DateTime.to_iso8601(entry.at)} class="tabular-nums text-fg-secondary">
            {local_time(entry.at)}
          </time>
        </li>
      </ol>
    </section>
    """
  end

  attr :at, DateTime, required: true

  # How the transcript of a failed run ends: a note as the transcript's other notes, in the colour of an error.
  # It takes back most of the room the scroller leaves between its parts, to follow the last item as one of them.
  defp failed_line(assigns) do
    ~H"""
    <div
      id="run-failed-line"
      class="divider m-0 -mt-2.5 h-auto gap-2 text-[11px] text-chip-error-fg before:h-px before:bg-base-300 after:h-px after:bg-base-300"
    >
      <span>
        status → failed · <time datetime={DateTime.to_iso8601(@at)}>{local_time(@at)}</time>
      </span>
    </div>
    """
  end

  # When the run failed: the last time it got that status, or its last update for a run without a history.
  defp failed_at(history, run) do
    case Enum.find(Enum.reverse(history), &(&1.status == :failed)) do
      %{at: at} -> at
      nil -> run.updated_at
    end
  end

  # The colour of a status as a dot, as the status chip has it.
  defp status_dot(:completed), do: "bg-primary"
  defp status_dot(:merged), do: "bg-dot-green"
  defp status_dot(:failed), do: "bg-dot-red"
  defp status_dot(:waiting_for_input), do: "bg-dot-orange"
  defp status_dot(:picked_up), do: "bg-dot-grey"
  defp status_dot(_status), do: "bg-dot-blue"

  defp abortable?(run), do: not Run.terminal?(run) and run.status != :handing_off

  # When the run was picked up, and how long it has taken since, as the runs table counts it.
  defp started(%{status: :picked_up} = run), do: "picked up #{local_time(run.inserted_at)}"
  defp started(run), do: "started #{local_time(run.inserted_at)} · #{run_duration(run)}"

  # A pull request by its number (`#221`) when the link ends in one, by the link itself otherwise.
  defp pr_label(url) do
    case Regex.run(~r{/pull/(\d+)/?$}, url) do
      [_, number] -> "##{number}"
      nil -> url
    end
  end

  defp status_text(:failed), do: "text-chip-error-fg"
  defp status_text(:completed), do: "text-primary"
  defp status_text(:merged), do: "text-chip-success-fg"
  defp status_text(:waiting_for_input), do: "text-chip-warning-fg"
  defp status_text(:picked_up), do: "text-fg-secondary"
  defp status_text(_status), do: "text-chip-info-fg"

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
        {:noreply, put_flash(socket, :error, message_error(reason))}
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
  # Another run: it only matters here as another attempt of the same issue.
  def handle_info(
        {:run_updated, %{id: id} = other},
        %{assigns: %{run: %{id: current} = run}} = socket
      )
      when id != current do
    if Map.get(other, :issue_key) == run.issue_key,
      do:
        {:noreply,
         assign(socket, attempts: Runs.other_attempts(run), retryable?: Runs.retryable?(run))},
      else: {:noreply, socket}
  end

  def handle_info({:run_updated, run}, socket) do
    run = Runs.get_run!(run.id)
    socket = if Run.terminal?(run), do: socket |> close_tail() |> assign(inbox: []), else: socket

    {:noreply,
     assign(socket,
       run: run,
       history: Runs.status_history(run.id),
       retryable?: Runs.retryable?(run)
     )}
  end

  def handle_info({:question, _question}, socket), do: {:noreply, assign_questions(socket)}

  def handle_info({:agent_event, %{conversation: conversation, role: role, event: event}}, socket) do
    # Messages go to the head agent, whichever conversation is on show.
    socket = if role == "head", do: track_inbox(socket, event), else: socket
    socket = socket |> track_model(conversation, event) |> track_end(conversation, event)

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

  # The model of a conversation is the one its first answer names; a snapshot may bring answers this page missed.
  defp track_model(%{assigns: %{models: models}} = socket, conversation, _event)
       when is_map_key(models, conversation),
       do: socket

  defp track_model(socket, conversation, %{
         "type" => "message_end",
         "entry" => %{"kind" => "pi.assistant", "model" => [message | _]}
       }) do
    case Runs.entry_model(message) do
      nil -> socket
      model -> assign(socket, models: Map.put(socket.assigns.models, conversation, model))
    end
  end

  defp track_model(socket, _conversation, %{"type" => "snapshot"}),
    do: assign(socket, models: Runs.conversation_models(socket.assigns.run.id))

  defp track_model(socket, _conversation, _event), do: socket

  # How a conversation last left off, from the events that say so; a snapshot may bring entries this page missed.
  defp track_end(socket, conversation, %{
         "type" => "message_end",
         "entry" => %{"kind" => kind} = entry
       }) do
    message = List.first(List.wrap(entry["model"])) || %{}
    put_end(socket, conversation, kind, message["stopReason"])
  end

  defp track_end(socket, conversation, %{"type" => type})
       when type in ~w(message_start tool_execution_start),
       do: put_end(socket, conversation, "tool_start", nil)

  defp track_end(socket, _conversation, %{"type" => "snapshot"}),
    do: assign(socket, ends: Runs.conversation_ends(socket.assigns.run.id))

  defp track_end(socket, _conversation, _event), do: socket

  defp put_end(socket, _conversation, "pi.system", _stop), do: socket

  defp put_end(socket, conversation, kind, stop),
    do:
      assign(socket,
        ends: Map.put(socket.assigns.ends, conversation, Runs.conversation_end(kind, stop))
      )

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
        socket = assign(socket, :transcript_changes, [])
        socket = Enum.reduce(parts(item), socket, &add_part(&2, &1))
        socket = if socket.assigns.busy, do: socket, else: close_tail(socket)
        flush_transcript_changes(socket)
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
        {parts, [%{kind: kind} = tail]} when busy and kind in ["steps", "response"] ->
          parts ++ [%{tail | active: true}]

        {parts, last} ->
          parts ++ last
      end

    turn = %{
      turn
      | parts: Enum.map(turn.parts, fn part -> Enum.find(parts, part, &(&1.id == part.id)) end)
    }

    groups =
      for part <- parts,
          part[:active] == true or open_calls(part) != [],
          into: %{},
          do: {part.id, part}

    tail = Enum.find_value(parts, &(&1[:active] && &1.id))

    socket
    |> assign(selected: conversation, live_text: "", live_thinking: "", live_tools: %{})
    |> assign(busy: busy, groups: groups, tail: tail, turn: turn)
    |> assign(first_prompt: Enum.find_value(items, &(&1.kind == "pi.user" && &1.id)))
    |> stream(:items, parts, reset: true)
  end

  # `groups` keeps the groups of steps that can still change: those waiting for a tool result, to put it on its
  # call, and the one at the end (`tail`), which takes the steps that follow until something else comes.
  defp add_part(socket, %{kind: "steps"} = part) do
    case socket.assigns.groups[socket.assigns.tail] do
      nil -> socket |> assign(tail: part.id) |> put_group(%{part | active: true})
      %{kind: "steps"} = tail -> put_group(socket, add_steps(tail, part))
      _ -> socket |> close_tail() |> add_part(part)
    end
  end

  # What the agent is told starts a turn. The first thing the conversation on show is told is the issue, as
  # `transcript/1` marks it in a transcript that is loaded; `first_prompt` is its id, also when it comes again
  # (a conversation that opens on its first event has loaded it already).
  defp add_part(socket, %{kind: "pi.user"} = part) do
    first = socket.assigns.first_prompt || part.id
    part = if part.id == first, do: Map.put(part, :first, true), else: part

    socket
    |> close_tail()
    |> assign(first_prompt: first, turn: %{started: sent_at(part), parts: []})
    |> change_transcript(:insert, part)
  end

  # The answer ends the turn: what led up to it folds into one part. The steps at the end are closed in the fold
  # itself, without publishing an intermediate update.
  defp add_part(socket, %{final: true} = part) do
    turn = socket.assigns.turn
    tail = socket.assigns.groups[socket.assigns.tail]

    closed =
      Enum.map(turn.parts, &if(tail && &1.id == tail.id, do: %{tail | active: false}, else: &1))

    socket =
      case work(%{turn | parts: closed}, part) do
        [%{kind: "work"} = work] ->
          closed
          |> Enum.reduce(socket, &change_transcript(&2, :delete, &1))
          |> assign(tail: nil, groups: Map.drop(socket.assigns.groups, Enum.map(closed, & &1.id)))
          |> change_transcript(:insert, work)

        _parts ->
          close_tail(socket)
      end

    socket |> assign(turn: %{started: nil, parts: []}) |> change_transcript(:insert, part)
  end

  defp add_part(socket, %{kind: "response"} = part) do
    socket = close_tail(socket)

    if call_ids(part) != [] do
      socket |> assign(tail: part.id) |> put_group(%{part | active: true})
    else
      put_part(socket, part)
    end
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

    socket |> assign(turn: %{turn | parts: parts}) |> change_transcript(:insert, part)
  end

  # A message can update a group and then fold it, or add a response that immediately goes into the fold.
  # LiveView keeps pending inserts even when stream_delete follows them in the same render. Publish only
  # the last operation for each row so a folded row cannot be reinserted alongside its work group.
  defp change_transcript(socket, operation, part) do
    case socket.assigns[:transcript_changes] do
      nil -> apply_transcript_change(socket, {operation, part})
      changes -> assign(socket, :transcript_changes, [{operation, part} | changes])
    end
  end

  defp flush_transcript_changes(socket) do
    changes =
      socket.assigns.transcript_changes
      |> Enum.uniq_by(fn {_operation, part} -> part.id end)
      |> Enum.reverse()

    socket
    |> assign(:transcript_changes, nil)
    |> then(
      &Enum.reduce(changes, &1, fn change, socket -> apply_transcript_change(socket, change) end)
    )
  end

  defp apply_transcript_change(socket, {:insert, part}), do: stream_insert(socket, :items, part)
  defp apply_transcript_change(socket, {:delete, part}), do: stream_delete(socket, :items, part)

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

  defp tabs(run, conversations, ends) do
    for {conversation, label} <- tab_labels(conversations),
        do: {conversation, label, tab_state(run, conversations, ends, conversation)}
  end

  # The state of a conversation, as the tab's dot and title say it. The head follows the run. A subagent follows its
  # last entry (what `Runs.conversation_ends/1` reads), but one that ended in an error has failed, and one that is
  # over (an earlier attempt, or the run is) is done whatever it ended with.
  defp tab_state(run, conversations, ends, conversation) do
    ended = ends[conversation]

    cond do
      head?(conversations, conversation) ->
        case run.status do
          :failed -> "failed"
          :completed -> "review"
          :merged -> "done"
          :waiting_for_input -> "waiting"
          _status -> "working"
        end

      ended == :error ->
        "failed"

      not latest_attempt?(conversations, conversation) or Run.terminal?(run) ->
        "done"

      ended in [nil, :working] ->
        "working"

      true ->
        "done"
    end
  end

  defp state_dot("working"), do: "bg-dot-blue"
  defp state_dot("waiting"), do: "bg-dot-orange"
  defp state_dot("done"), do: "bg-dot-green"
  defp state_dot("review"), do: "bg-primary"
  defp state_dot("failed"), do: "bg-dot-red"

  defp state_text("waiting"), do: "Waiting for input"
  defp state_text("review"), do: "In review"
  defp state_text(state), do: String.capitalize(state)

  # What a tab says when it is pointed at: its state, so the dot is not the only way to tell, and for a subagent the
  # model of its conversation once that is known. The head's model is in the details.
  defp tab_title(state, conversations, conversation, models) do
    model = if head?(conversations, conversation), do: nil, else: models[conversation]

    [state_text(state), model && model_text(model)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  # The model the conversation on show ran on: what the run was started with for the head agent (what its answers
  # name for a run from before that was kept), and what its answers name for a subagent.
  defp model(run, conversations, selected, models) do
    if head?(conversations, selected),
      do: (run.models || %{})["head"] || models[selected],
      else: models[selected]
  end

  defp model_id(%{"provider" => provider, "modelId" => id}), do: "#{provider}/#{id}"
  defp model_id(%{"modelId" => id}), do: id

  defp model_text(%{"reasoning" => level} = model) when is_binary(level),
    do: "#{model_id(model)} · #{level}"

  defp model_text(model), do: model_id(model)

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

  defp message_error(:pr_merged), do: "This pull request has been merged. The run is done."

  defp message_error(:pr_closed),
    do: "This pull request is closed. Reopen it before sending feedback."

  defp message_error(:concurrency_limit),
    do: "All agent slots are occupied. Try sending feedback when a slot is free."

  defp message_error(:workspace_unavailable),
    do: "The original workspace is unavailable; this run cannot be resumed."

  defp message_error(:empty_message), do: "Enter a message first."
  defp message_error(reason), do: "Could not send the message: #{inspect(reason)}"

  defp prompt_placeholder(:completed, _head?), do: "Send review feedback to the agent"
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
