defmodule ConductorWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :conductor

  # Only the CSRF token and flash live in the session.
  @session_options [
    store: :cookie,
    key: "_conductor_key",
    signing_salt: "symSn+If",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :conductor,
    gzip: not code_reloading?,
    only: ConductorWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  if Mix.env() == :dev do
    plug Tidewave
  end

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :conductor
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Head
  plug Plug.Session, @session_options
  plug ConductorWeb.Router
end
