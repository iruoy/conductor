defmodule ConductorWeb.DashboardLive do
  use ConductorWeb, :live_view
  alias Conductor.{Coordinator, Poller, Runs}

  @log_limit 200

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Runs.subscribe()

    {:ok,
     socket
     |> assign(page_title: "Runs", selected: nil, log_seq: 0)
     |> stream(:runs, Runs.list_runs())
     |> stream(:log, [])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_page={:runs}>
      <div class="mx-auto max-w-6xl space-y-6 p-4 sm:p-6">
        <.header>
          Runs
          <:subtitle>Issues picked up from GitHub, newest first.</:subtitle>
          <:actions>
            <.button id="poll-now" phx-click="poll_now">
              <.icon name="hero-arrow-path" class="size-4" /> Poll now
            </.button>
          </:actions>
        </.header>

        <div class="overflow-x-auto rounded-box border border-base-300">
          <table class="table">
            <thead>
              <tr>
                <th>Run</th>
                <th>Issue</th>
                <th>Status</th>
                <th>PR</th>
                <th>Updated</th>
                <th><span class="sr-only">Actions</span></th>
              </tr>
            </thead>
            <tbody id="runs" phx-update="stream">
              <tr id="runs-empty" class="hidden only:table-row">
                <td colspan="6" class="py-8 text-center text-base-content/60">No runs yet.</td>
              </tr>
              <tr
                :for={{dom_id, run} <- @streams.runs}
                id={dom_id}
                class={["hover:bg-base-200/60", @selected == run.id && "bg-base-200"]}
              >
                <td class="font-mono text-sm">
                  <.link navigate={~p"/runs/#{run.id}"} class="link link-hover">{run.id}</.link>
                </td>
                <td class="max-w-md truncate text-sm">{(run.issue_snapshot || %{})["summary"]}</td>
                <td>
                  <.status_badge status={run.status} />
                  <div
                    :if={run.status == :failed && run.error}
                    class="mt-1 max-w-xs truncate text-xs text-error"
                  >
                    {run.error}
                  </div>
                </td>
                <td>
                  <a
                    :if={run.pr_url}
                    href={run.pr_url}
                    target="_blank"
                    class="link link-primary text-sm"
                  >Open PR</a>
                </td>
                <td class="whitespace-nowrap text-xs text-base-content/60">
                  {format_time(run.updated_at)}
                </td>
                <td class="whitespace-nowrap text-right">
                  <button
                    id={"log-#{run.id}"}
                    phx-click="select"
                    phx-value-id={run.id}
                    class="btn btn-ghost btn-xs"
                    title="Live log"
                  >
                    <.icon name="hero-command-line" class="size-4" />
                  </button>
                  <button
                    :if={Conductor.Runs.Run.terminal?(run)}
                    id={"retry-#{run.id}"}
                    phx-click="retry"
                    phx-value-id={run.id}
                    class="btn btn-ghost btn-xs"
                  >
                    Retry
                  </button>
                  <button
                    :if={not Conductor.Runs.Run.terminal?(run) and run.status != :handing_off}
                    id={"abort-#{run.id}"}
                    phx-click={show_modal("confirm-abort-#{run.id}")}
                    class="btn btn-ghost btn-xs text-error"
                  >
                    Abort
                  </button>
                  <.confirm_modal
                    :if={not Conductor.Runs.Run.terminal?(run) and run.status != :handing_off}
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

        <section :if={@selected} class="card card-border card-sm border-base-300">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <h2 class="card-title text-sm">
                Live log ·
                <.link navigate={~p"/runs/#{@selected}"} class="link font-mono">{@selected}</.link>
              </h2>
              <div class="card-actions">
                <button phx-click="select" phx-value-id="" class="btn btn-ghost btn-xs">Close</button>
              </div>
            </div>
            <div id="log" phx-update="stream" class="max-h-96 overflow-y-auto font-mono text-xs">
              <div id="log-empty" class="hidden py-2 text-base-content/50 only:block">
                Waiting for activity…
              </div>
              <div :for={{dom_id, line} <- @streams.log} id={dom_id} class="flex gap-2 py-0.5">
                <span class="shrink-0 text-base-content/50">{line.role}</span>
                <span class={["break-all", line.class]}>{line.text}</span>
              </div>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("poll_now", _params, socket) do
    if Process.whereis(Poller), do: Poller.poll_now()
    {:noreply, put_flash(socket, :info, "Polling GitHub…")}
  end

  def handle_event("select", %{"id" => id}, socket) do
    if socket.assigns.selected, do: Runs.unsubscribe(socket.assigns.selected)
    selected = if id == "", do: nil, else: id
    if selected, do: Runs.subscribe(selected)

    {:noreply,
     socket
     |> assign(selected: selected)
     |> stream(:log, [], reset: true)
     |> stream(:runs, Runs.list_runs())}
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
    socket = stream_insert(socket, :runs, run, at: if(new_run?(socket, run), do: 0, else: -1))

    socket =
      if run.id == socket.assigns.selected,
        do: log(socket, "conductor", "status → #{run.status}", "text-info"),
        else: socket

    {:noreply, socket}
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

  # A run inserted for the first time goes to the top; updates keep their place.
  defp new_run?(_socket, run), do: run.inserted_at == run.updated_at and run.status == :picked_up

  defp format_time(nil), do: ""
  defp format_time(datetime), do: Calendar.strftime(datetime, "%d %b %H:%M")
end
