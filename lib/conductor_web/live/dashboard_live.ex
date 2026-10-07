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
    runs = Runs.list_runs()

    {:ok,
     socket
     |> assign(page_title: "Runs", selected: nil, log_seq: 0, now: DateTime.utc_now())
     |> assign(interval: interval, last_poll: last_poll)
     |> track_runs(runs)
     |> stream(:runs, runs)
     |> stream(:log, [])}
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
        <div id="runs-table" class="flex-1 overflow-x-auto">
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
              <tr id="runs-empty" class="hidden only:table-row">
                <td colspan="6" class="px-3 py-6 text-center text-fg-secondary">No runs yet.</td>
              </tr>
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
        </div>

        <section :if={@selected} id="live-log" class="border-t border-base-300 bg-base-100">
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
            class="max-h-72 overflow-y-auto px-3 py-1.5 font-mono text-[11.5px] leading-normal"
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

        <footer
          id="runs-footer"
          class="flex h-[26px] items-center justify-end gap-3 border-t border-base-300 bg-surface-2 px-3 text-[11px] text-fg-secondary"
        >
          <span id="runs-count">{@run_count} of {@run_count} runs</span>
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

  def handle_event("select", %{"id" => id}, socket) do
    if socket.assigns.selected, do: Runs.unsubscribe(socket.assigns.selected)
    selected = if id == "", do: nil, else: id
    if selected, do: Runs.subscribe(selected)

    runs = Runs.list_runs()

    {:noreply,
     socket
     |> assign(selected: selected, now: DateTime.utc_now())
     |> stream(:log, [], reset: true)
     |> track_runs(runs)
     |> stream(:runs, runs)}
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
    # A run inserted for the first time goes to the top; updates keep their place.
    at = if MapSet.member?(socket.assigns.run_ids, run.id), do: -1, else: 0

    socket =
      socket
      |> assign(now: DateTime.utc_now())
      |> track_runs([run])
      |> stream_insert(:runs, run, at: at)

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

  # Streams cannot be counted, so the ids on the page are kept to count them and to tell a new run from an update.
  defp track_runs(socket, runs) do
    ids = Enum.into(runs, socket.assigns[:run_ids] || MapSet.new(), & &1.id)
    assign(socket, run_ids: ids, run_count: MapSet.size(ids))
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
