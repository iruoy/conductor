defmodule ConductorWeb.WaitingCount do
  @moduledoc """
  `on_mount` hook that keeps `:waiting_count`, the number of runs waiting for input, current on every LiveView of a
  live session, so the nav can show it.

  The hook owns the one subscription to the `"runs"` topic. It never swallows `{:run_updated, run}`: LiveViews that
  handle that message themselves (`@forwarding`) still receive it; for the others the hook is the last stop.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]
  alias Conductor.Runs

  @forwarding [ConductorWeb.DashboardLive, ConductorWeb.RunLive]

  def on_mount(:default, _params, _session, socket) do
    socket = assign(socket, :waiting_count, Runs.waiting_count())

    if connected?(socket) do
      Runs.subscribe()
      {:cont, attach_hook(socket, :waiting_count, :handle_info, &handle_info/2)}
    else
      {:cont, socket}
    end
  end

  defp handle_info({:run_updated, _run}, socket) do
    socket = assign(socket, :waiting_count, Runs.waiting_count())
    if socket.view in @forwarding, do: {:cont, socket}, else: {:halt, socket}
  end

  defp handle_info(_message, socket), do: {:cont, socket}
end
