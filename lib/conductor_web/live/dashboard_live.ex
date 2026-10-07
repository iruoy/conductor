defmodule ConductorWeb.DashboardLive do
  use ConductorWeb, :live_view
  alias Conductor.{Coordinator, Poller, Runs}
  alias Conductor.Runs.Run

  @log_limit 200
  # A run that is under way shows its duration up to now, to the minute.
  @tick :timer.minutes(1)
  @under_way Run.statuses() -- [:picked_up | Run.terminal_statuses()]

  @impl true
  def mount(_params, _session, socket) do
    # The "runs" topic is subscribed by the ConductorWeb.WaitingCount hook of the live session.
    if connected?(socket) do
      Poller.subscribe()
      Process.send_after(self(), :tick, @tick)
    end

    %{interval: interval, last_poll: last_poll} = Poller.status()

    # The runs themselves are read by handle_params/3, which knows the filter.
    {:ok,
     socket
     |> assign(page_title: "Runs", selected: nil, log_seq: 0, now: DateTime.utc_now())
     |> assign(interval: interval, last_poll: last_poll)
     |> assign(group: :all, text: "", run_ids: MapSet.new())
     |> assign(counts: %{}, shown_count: 0, total_count: 0)
     |> stream(:runs, [])
     |> stream(:log, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    group = parse_group(params["status"])
    text = String.trim(to_string(params["q"] || ""))

    {:noreply,
     socket
     |> assign(group: group, text: text, now: DateTime.utc_now())
     |> load_runs()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_page={:runs} waiting_count={@waiting_count}>
      <:actions>
        <div
          id="github-checked"
          title={@last_poll && @last_poll.reason}
          class="hidden items-center gap-1.5 text-xs text-fg-secondary sm:flex"
        >
          <span
            id="github-checked-dot"
            class={[
              "size-1.5 rounded-full",
              cond do
                is_nil(@last_poll) -> "bg-dot-grey"
                @last_poll.ok? -> "bg-dot-green"
                true -> "bg-dot-red"
              end
            ]}
          ></span>
          {checked_text(@last_poll, @interval)}
        </div>
        <button
          id="poll-now"
          type="button"
          phx-click="poll_now"
          title="Look for new issues to pick up without waiting for the next check"
          class="btn btn-sm h-7 min-h-0 gap-1.5 border-line-strong bg-base-100 px-2.5 text-xs font-medium"
        >
          <.icon name="hero-arrow-path" class="size-3.5" /> Check GitHub
        </button>
      </:actions>
      <%!-- Fills the window below the header (2.5rem and its border), so the footer sits at the bottom. --%>
      <div class="flex min-h-[calc(100dvh-2.5rem-1px)] flex-col">
        <div
          id="runs-filters"
          class="flex flex-wrap items-center gap-1 border-b border-base-300 bg-surface-2 px-3 py-2"
        >
          <div role="group" aria-label="Filter by status" class="flex flex-wrap gap-1">
            <button
              :for={{group, label, dot} <- filter_chips()}
              id={"filter-#{group}"}
              type="button"
              phx-click="filter"
              phx-value-status={group}
              aria-pressed={to_string(@group == group)}
              class={[
                "inline-flex h-6 cursor-pointer items-center gap-[5px] rounded-full border px-2 text-xs transition-colors",
                if(@group == group,
                  do: "border-base-content bg-base-content text-base-100",
                  else: "border-line-strong bg-base-100 hover:bg-row-hover"
                )
              ]}
            >
              <span :if={dot} class={["size-1.5 rounded-full", dot]}></span>
              {label}
              <span id={"filter-count-#{group}"} class="opacity-70">{@counts[group]}</span>
            </button>
          </div>
          <div class="flex-1"></div>
          <.form
            for={to_form(%{"q" => @text}, as: :filter)}
            id="runs-search-form"
            phx-change="search"
            phx-submit="search"
            class="w-full sm:w-[220px]"
          >
            <label class="flex h-6 items-center gap-1.5 rounded border border-line-strong bg-base-100 px-2 text-fg-secondary">
              <.icon name="hero-magnifying-glass-micro" class="size-3 shrink-0" />
              <input
                id="runs-search"
                type="text"
                name="filter[q]"
                value={@text}
                autocomplete="off"
                aria-label="Filter runs"
                placeholder="Filter by issue or run"
                phx-debounce="250"
                class="min-w-0 flex-1 border-0 bg-transparent p-0 text-xs text-base-content outline-0 placeholder:text-fg-secondary focus:ring-0"
              />
            </label>
          </.form>
        </div>
        <div class="flex min-h-0 flex-1 flex-wrap">
          <div id="runs-table" class="min-w-0 flex-[999_1_640px] overflow-x-auto">
            <table class="w-full border-collapse text-[13px]">
              <thead>
                <tr class="text-left text-[11px] uppercase tracking-[0.04em] text-fg-secondary *:border-b *:border-base-300 *:bg-surface-2 *:py-1.5 *:font-medium">
                  <th class="px-3">Run</th>
                  <th class="px-2">Issue</th>
                  <th class="px-2">Status</th>
                  <th class="px-2 text-right">Duration</th>
                  <th class="px-2 text-right">Updated</th>
                  <th class="px-3"><span class="sr-only">Actions</span></th>
                </tr>
              </thead>
              <tbody id="runs" phx-update="stream">
                <tr
                  :for={{dom_id, run} <- @streams.runs}
                  id={dom_id}
                  data-status={run.status}
                  class={[
                    "h-[30px] border-b border-muted transition-colors hover:bg-row-hover",
                    cond do
                      @selected == run.id -> "bg-row-selected"
                      run.status == :waiting_for_input -> "bg-row-waiting"
                      true -> nil
                    end
                  ]}
                >
                  <td class={[
                    "whitespace-nowrap px-3 font-mono text-xs",
                    run.status == :waiting_for_input && "shadow-[inset_3px_0_0_var(--dot-orange)]"
                  ]}>
                    <.link
                      id={"open-#{run.id}"}
                      navigate={~p"/runs/#{run.id}"}
                      class="text-link hover:text-link-hover hover:underline"
                    >{run.id}</.link>
                  </td>
                  <td class={[
                    "max-w-[380px] truncate px-2",
                    run.status == :waiting_for_input && "font-medium"
                  ]}>
                    {(run.issue_snapshot || %{})["summary"]}
                  </td>
                  <td class="whitespace-nowrap px-2">
                    <.status_badge id={"status-#{run.id}"} status={run.status} />
                    <a
                      :if={run.pr_url}
                      id={"pr-#{run.id}"}
                      href={run.pr_url}
                      target="_blank"
                      class="ml-1.5 inline-flex items-center gap-[3px] align-middle text-xs text-link hover:text-link-hover hover:underline"
                    >
                      <.icon name="hero-arrow-top-right-on-square-micro" class="size-3" />
                      {pr_label(run.pr_url)}
                    </a>
                    <.link
                      :if={run.status == :waiting_for_input}
                      id={"answer-#{run.id}"}
                      navigate={~p"/runs/#{run.id}"}
                      class="ml-1.5 inline-flex h-5 items-center rounded border border-dot-orange px-2 align-middle text-[11px] font-medium text-chip-warning-fg transition-colors hover:bg-chip-warning-bg"
                    >
                      Answer
                    </.link>
                    <span
                      :if={run.status == :failed && run.error}
                      id={"error-#{run.id}"}
                      title={run.error}
                      class="ml-1.5 inline-block max-w-xs truncate align-middle text-xs text-chip-error-fg"
                    >
                      {run.error}
                    </span>
                  </td>
                  <td
                    id={"duration-#{run.id}"}
                    class={[
                      "whitespace-nowrap px-2 text-right text-xs tabular-nums",
                      if(under_way?(run), do: "text-base-content", else: "text-fg-secondary")
                    ]}
                  >
                    {run_duration(run, @now)}
                  </td>
                  <td
                    id={"updated-#{run.id}"}
                    class="whitespace-nowrap px-2 text-right text-xs tabular-nums text-fg-secondary"
                  >
                    {local_time(run.updated_at)}
                  </td>
                  <td class="whitespace-nowrap py-0 pl-1 pr-2 text-right">
                    <div class="inline-flex items-center gap-0.5">
                      <button
                        :if={run.status == :failed}
                        id={"retry-#{run.id}"}
                        type="button"
                        phx-click="retry"
                        phx-value-id={run.id}
                        class="btn btn-ghost h-6 min-h-0 px-1.5 text-xs font-normal"
                      >
                        Retry
                      </button>
                      <button
                        :if={not Run.terminal?(run) and run.status != :handing_off}
                        id={"abort-#{run.id}"}
                        type="button"
                        phx-click={show_modal("confirm-abort-#{run.id}")}
                        class="btn btn-ghost h-6 min-h-0 px-1.5 text-xs font-normal text-chip-error-fg"
                      >
                        Abort
                      </button>
                      <button
                        id={"log-#{run.id}"}
                        type="button"
                        phx-click="select"
                        phx-value-id={if @selected == run.id, do: "", else: run.id}
                        aria-label={"Live log for #{run.id}"}
                        aria-pressed={to_string(@selected == run.id)}
                        title="Live log"
                        class="btn btn-ghost size-6 min-h-0 p-0 text-fg-secondary aria-pressed:bg-muted aria-pressed:text-base-content"
                      >
                        <.icon name="hero-command-line-micro" class="size-3.5" />
                      </button>
                    </div>
                    <.confirm_modal
                      :if={not Run.terminal?(run) and run.status != :handing_off}
                      id={"confirm-abort-#{run.id}"}
                      title={"Abort #{run.id}?"}
                      confirm="Abort"
                      on_confirm={JS.push("abort", value: %{id: run.id})}
                    >
                      The agent stops and the run is marked as failed.
                    </.confirm_modal>
                  </td>
                </tr>
              </tbody>
            </table>
            <p
              :if={@shown_count == 0}
              id="runs-empty"
              class="px-3 py-6 text-center text-[13px] text-fg-secondary"
            >
              {if @total_count == 0, do: "No runs yet.", else: "No runs match this filter."}
            </p>
          </div>

          <section
            :if={@selected}
            id="live-log"
            aria-label="Live log"
            class="flex min-w-0 flex-[1_1_360px] flex-col border-t border-base-300 bg-base-100 lg:border-l lg:border-t-0"
          >
            <div class="flex h-8 items-center gap-1.5 border-b border-base-300 pl-3 pr-2">
              <span class="size-1.5 rounded-full bg-dot-blue"></span>
              <h2 class="text-xs font-semibold">Live log</h2>
              <.link
                navigate={~p"/runs/#{@selected}"}
                class="font-mono text-xs text-link hover:text-link-hover hover:underline"
              >{@selected}</.link>
              <button
                id="log-close"
                type="button"
                phx-click="select"
                phx-value-id=""
                aria-label="Close live log"
                class="btn btn-ghost ml-auto size-6 min-h-0 p-0 text-fg-secondary"
              >
                <.icon name="hero-x-mark-micro" class="size-3.5" />
              </button>
            </div>
            <div
              id="log"
              phx-update="stream"
              class="max-h-72 min-h-0 flex-1 overflow-y-auto px-3 py-1.5 font-mono text-[11.5px] leading-normal lg:max-h-none"
            >
              <div id="log-empty" class="hidden text-fg-tertiary only:block">
                Waiting for activity…
              </div>
              <div :for={{dom_id, line} <- @streams.log} id={dom_id} class="flex gap-2">
                <span class="w-16 shrink-0 text-fg-tertiary">{line.role}</span>
                <span class={["min-w-0 break-all", line.class]}>{line.text}</span>
              </div>
            </div>
          </section>
        </div>

        <footer
          id="runs-footer"
          class="flex h-[26px] items-center justify-end gap-3 border-t border-base-300 bg-surface-2 px-3 text-[11px] text-fg-secondary"
        >
          <span id="runs-count">{@shown_count} of {@total_count} runs</span>
        </footer>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("poll_now", _params, socket) do
    if Process.whereis(Poller), do: Poller.poll_now()
    {:noreply, put_flash(socket, :info, "Checking GitHub for new issues…")}
  end

  def handle_event("filter", %{"status" => status}, socket) do
    {:noreply, push_patch(socket, to: filter_path(parse_group(status), socket.assigns.text))}
  end

  def handle_event("search", %{"filter" => %{"q" => q}}, socket) do
    {:noreply, push_patch(socket, to: filter_path(socket.assigns.group, q))}
  end

  def handle_event("select", %{"id" => id}, socket) do
    if socket.assigns.selected, do: Runs.unsubscribe(socket.assigns.selected)
    selected = if id == "", do: nil, else: id
    if selected, do: Runs.subscribe(selected)

    {:noreply,
     socket
     |> assign(selected: selected, now: DateTime.utc_now())
     |> stream(:log, [], reset: true)
     |> load_runs()}
  end

  def handle_event("retry", %{"id" => id}, socket) do
    case Coordinator.retry(id) do
      {:ok, run} ->
        {:noreply, put_flash(socket, :info, "Queued #{run.id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cannot retry: #{inspect(reason)}")}
    end
  end

  def handle_event("abort", %{"id" => id}, socket) do
    case Coordinator.abort(id) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Aborting #{id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cannot abort: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:run_updated, run}, socket) do
    %{run_ids: run_ids, group: group, text: text} = socket.assigns
    shown? = MapSet.member?(run_ids, run.id)

    socket =
      cond do
        # A run inserted for the first time goes to the top; updates keep their place.
        Runs.matches?(run, group, text) ->
          socket
          |> track_runs([run])
          |> stream_insert(:runs, run, at: if(shown?, do: -1, else: 0))

        # A run that left the filter goes; one that never was in it stays out.
        shown? ->
          socket |> untrack_run(run) |> stream_delete(:runs, run)

        true ->
          socket
      end

    socket = socket |> assign(now: DateTime.utc_now()) |> assign_counts()

    socket =
      if run.id == socket.assigns.selected,
        do: log(socket, "conductor", "status → #{run.status}", "text-info"),
        else: socket

    {:noreply, socket}
  end

  # Only the rows whose duration still grows are sent again.
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick)

    runs =
      Enum.filter(Runs.list_by_status(@under_way), &MapSet.member?(socket.assigns.run_ids, &1.id))

    {:noreply,
     Enum.reduce(
       runs,
       assign(socket, now: DateTime.utc_now()),
       &stream_insert(&2, :runs, &1, at: -1)
     )}
  end

  def handle_info({:polled, last_poll}, socket) do
    {:noreply, assign(socket, :last_poll, last_poll)}
  end

  def handle_info({:agent_event, %{role: role, event: event}}, socket) do
    {:noreply, log_event(socket, role, event)}
  end

  def handle_info({:question, question}, socket) do
    {:noreply, log(socket, "human?", question.text, "text-warning")}
  end

  defp log_event(socket, role, %{
         "type" => "message_end",
         "entry" => %{"kind" => "pi.assistant"} = entry
       }) do
    text = message_text(entry) |> String.trim()
    if text == "", do: socket, else: log(socket, role, truncate(text, 400), "")
  end

  defp log_event(socket, role, %{
         "type" => "tool_execution_start",
         "toolName" => name,
         "args" => args
       }) do
    log(socket, role, "#{name} #{truncate(tool_call(name, args), 200)}", "text-base-content/70")
  end

  defp log_event(socket, role, %{"type" => "auto_retry_start", "errorMessage" => message}) do
    log(socket, role, "retrying: #{message}", "text-warning")
  end

  defp log_event(socket, _role, _event), do: socket

  defp log(socket, role, text, class) do
    seq = socket.assigns.log_seq + 1

    socket
    |> assign(log_seq: seq)
    |> stream_insert(:log, %{id: "log-#{seq}", role: role, text: text, class: class},
      limit: -@log_limit
    )
  end

  # Reads the runs of the current filter again and resets the stream.
  defp load_runs(socket) do
    runs = Runs.filter_runs(socket.assigns.group, socket.assigns.text)

    socket
    |> assign(run_ids: MapSet.new(runs, & &1.id))
    |> assign_counts()
    |> stream(:runs, runs, reset: true)
  end

  # The numbers are true counts from the database, not the length of the (capped) list on the page:
  # the chips count per status group, the footer counts the runs of the filter against all runs.
  defp assign_counts(socket) do
    %{group: group, text: text} = socket.assigns
    counts = Runs.group_counts()

    assign(socket,
      counts: counts,
      shown_count: Runs.count_runs(group, text),
      total_count: counts.all
    )
  end

  # Streams cannot be counted, so the ids on the page are kept to tell a new run from an update.
  defp track_runs(socket, runs) do
    assign(socket, :run_ids, Enum.into(runs, socket.assigns.run_ids, & &1.id))
  end

  defp untrack_run(socket, run),
    do: assign(socket, :run_ids, MapSet.delete(socket.assigns.run_ids, run.id))

  defp parse_group(status) do
    Enum.find(Runs.status_groups(), :all, &(Atom.to_string(&1) == status))
  end

  defp filter_path(group, text) do
    params =
      [
        status: if(group != :all, do: group),
        q: if(String.trim(text) != "", do: String.trim(text))
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    ~p"/?#{params}"
  end

  defp filter_chips do
    [
      {:all, "All", nil},
      {:running, "Running", "bg-dot-blue"},
      {:waiting, "Waiting for input", "bg-dot-orange"},
      {:completed, "Completed", "bg-dot-green"},
      {:failed, "Failed", "bg-dot-red"},
      {:picked_up, "Picked up", "bg-dot-grey"}
    ]
  end

  defp under_way?(run), do: run.status in @under_way

  # The number of a pull request is the last segment of its URL.
  defp pr_label(url) do
    number = url |> String.trim_trailing("/") |> String.split("/") |> List.last()
    if number =~ ~r/^\d+$/, do: "PR ##{number}", else: "PR"
  end

  defp checked_text(nil, _interval), do: "GitHub not checked yet"

  defp checked_text(%{at: at}, interval),
    do: ["GitHub checked ", local_time(at), interval_text(interval)]

  defp interval_text(nil), do: ""
  defp interval_text(60_000), do: " · every minute"

  defp interval_text(ms) when rem(ms, 3_600_000) == 0,
    do: " · every #{unit(div(ms, 3_600_000), "hour")}"

  defp interval_text(ms) when rem(ms, 60_000) == 0,
    do: " · every #{unit(div(ms, 60_000), "minute")}"

  defp interval_text(ms), do: " · every #{unit(max(div(ms, 1000), 1), "second")}"

  defp unit(1, name), do: name
  defp unit(n, name), do: "#{n} #{name}s"
end
