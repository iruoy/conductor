defmodule ConductorWeb do
  @moduledoc """
  The entrypoint for the web interface: `use ConductorWeb, :live_view` (or `:html`, `:router`, `:verified_routes`).
  """

  def static_paths, do: ~w(assets fonts favicon.ico)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller, only: [get_csrf_token: 0]

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import ConductorWeb.CoreComponents
      import ConductorWeb.RunComponents

      alias Phoenix.LiveView.JS
      alias ConductorWeb.Layouts

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: ConductorWeb.Endpoint,
        router: ConductorWeb.Router,
        statics: ConductorWeb.static_paths()
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
