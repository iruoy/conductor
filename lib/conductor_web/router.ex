defmodule ConductorWeb.Router do
  use ConductorWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ConductorWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ConductorWeb do
    pipe_through :browser

    live_session :default, on_mount: ConductorWeb.WaitingCount do
      live "/", DashboardLive
      live "/runs/:id", RunLive
      live "/config", ConfigLive
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", ConductorWeb do
  #   pipe_through :api
  # end
end
