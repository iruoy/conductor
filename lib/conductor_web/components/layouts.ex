defmodule ConductorWeb.Layouts do
  @moduledoc "The root layout and the app shell: header, nav, theme switch and flash messages."
  use ConductorWeb, :html

  embed_templates "layouts/*"

  @doc "The app shell every LiveView renders its content in."
  attr :flash, :map, required: true, doc: "the map of flash messages"

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
          class="btn btn-ghost btn-xs h-7 whitespace-nowrap px-2 font-normal"
        >
          Runs
          <span
            :if={@waiting_count > 0}
            id="nav-waiting-count"
            title={
              if(@waiting_count == 1,
                do: "1 run waiting for input",
                else: "#{@waiting_count} runs waiting for input"
              )
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
          class="btn btn-ghost btn-xs h-7 whitespace-nowrap px-2 font-normal"
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

  attr :flash, :map, required: true

  defp flash_group(assigns) do
    ~H"""
    <div id="flash-group" aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  # The theme script in root.html.heex applies the choice before the page loads.
  defp theme_toggle(assigns) do
    ~H"""
    <%!-- aria-pressed is kept in sync by the theme script in root.html.heex, so LiveView must leave it alone. --%>
    <div
      id="theme-toggle"
      role="group"
      aria-label="Theme"
      class="flex items-center gap-0.5"
      phx-update="ignore"
    >
      <button
        :for={
          {theme, label, icon} <- [
            {"light", "Use light theme", "hero-sun-micro"},
            {"system", "Use system theme", "hero-computer-desktop-micro"},
            {"dark", "Use dark theme", "hero-moon-micro"}
          ]
        }
        id={"theme-#{theme}"}
        type="button"
        aria-label={label}
        aria-pressed="false"
        class="btn btn-ghost btn-xs size-6 min-h-0 p-0"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme={theme}
      >
        <.icon name={icon} class="size-4" />
      </button>
    </div>
    """
  end
end
