defmodule ConductorWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use ConductorWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :current_page, :atom,
    default: nil,
    values: [nil, :runs, :config],
    doc: "the page the nav marks as current"

  attr :waiting_count, :integer,
    default: 0,
    doc: "the number of runs waiting for input, shown next to the Runs link"

  slot :actions, doc: "page actions, shown on the right of the header before the theme switch"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header
      id="app-header"
      class="sticky top-0 z-30 flex h-10 items-center gap-3 border-b border-base-300 bg-base-100 px-3"
    >
      <.link navigate={~p"/"} class="flex items-center gap-1.5 font-semibold">
        <.icon name="hero-musical-note" class="size-4 text-primary" /> Conductor
      </.link>
      <nav id="app-nav" class="flex items-center gap-1">
        <.link
          id="nav-runs"
          navigate={~p"/"}
          aria-current={@current_page == :runs && "page"}
          class="whitespace-nowrap rounded px-2 py-1 text-fg-secondary hover:bg-row-hover aria-[current=page]:bg-muted aria-[current=page]:text-base-content"
        >
          Runs
          <span
            :if={@waiting_count > 0}
            id="nav-waiting-count"
            title={
              ngettext("1 run waiting for input", "%{count} runs waiting for input", @waiting_count)
            }
            class="ml-1 rounded-full bg-chip-warning-bg px-1.5 text-xs font-medium text-chip-warning-fg"
          >
            {@waiting_count}
          </span>
        </.link>
        <.link
          id="nav-config"
          navigate={~p"/config"}
          aria-current={@current_page == :config && "page"}
          class="whitespace-nowrap rounded px-2 py-1 text-fg-secondary hover:bg-row-hover aria-[current=page]:bg-muted aria-[current=page]:text-base-content"
        >
          Config
        </.link>
      </nav>
      <div class="ml-auto flex shrink-0 items-center gap-2">
        <div :if={@actions != []} id="header-actions" class="flex items-center gap-2">
          {render_slot(@actions)}
        </div>
        <.theme_toggle />
      </div>
    </header>

    <main id="main">
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <%!-- aria-pressed is kept in sync by the theme script in root.html.heex, so LiveView must leave it alone. --%>
    <div
      id="theme-toggle"
      role="group"
      aria-label={gettext("Theme")}
      class="flex items-center gap-0.5"
      phx-update="ignore"
    >
      <button
        :for={
          {theme, label, icon} <- [
            {"light", gettext("Use light theme"), "hero-sun-micro"},
            {"system", gettext("Use system theme"), "hero-computer-desktop-micro"},
            {"dark", gettext("Use dark theme"), "hero-moon-micro"}
          ]
        }
        id={"theme-#{theme}"}
        type="button"
        aria-label={label}
        aria-pressed="false"
        class="flex size-6 cursor-pointer items-center justify-center rounded text-fg-tertiary transition-colors hover:bg-row-hover aria-pressed:bg-muted aria-pressed:text-base-content"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme={theme}
      >
        <.icon name={icon} class="size-4" />
      </button>
    </div>
    """
  end
end
