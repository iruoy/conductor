defmodule ConductorWeb.CoreComponents do
  @moduledoc "The shared UI components: flash, form inputs, table, icon and confirm dialog, styled with daisyUI."
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc "Renders a flash notice: the message of `kind` in `flash`, or the inner block."
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      phx-hook={@kind == :info && "#{inspect(__MODULE__)}.AutoDismiss"}
      role="alert"
      class="toast toast-bottom toast-end z-50 p-3 [&[hidden]]:hidden"
      {@rest}
    >
      <div class="flex max-w-sm items-center gap-2 rounded-box bg-neutral px-3 py-2 text-neutral-content shadow-lg">
        <span class={[
          "size-2 shrink-0 rounded-full",
          @kind == :info && "bg-dot-blue",
          @kind == :error && "bg-dot-red"
        ]} />
        <p class="min-w-0 text-wrap">
          <span :if={@title} class="font-semibold">{@title} </span>{msg}
        </p>
        <button
          type="button"
          class="group -mr-1 flex size-5 shrink-0 cursor-pointer items-center justify-center rounded"
          aria-label="close"
        >
          <.icon name="hero-x-mark" class="size-3.5 opacity-60 group-hover:opacity-100" />
        </button>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".AutoDismiss">
      // Info messages close themselves; a new message restarts the wait.
      export default {
        mounted() { this.wait() },
        updated() { this.wait() },
        destroyed() { clearTimeout(this.timer) },
        wait() {
          clearTimeout(this.timer)
          this.timer = setTimeout(() => this.el.click(), 4000)
        }
      }
    </script>
    """
  end

  @doc """
  Renders an input with label and error messages, from a `Phoenix.HTML.FormField` or explicit attributes. The type
  `select` renders a `<select>` with `options` (see `Phoenix.HTML.Form.options_for_select/2`).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string, default: "text", values: ~w(checkbox number select text textarea)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :rest, :global, include: ~w(disabled form max min placeholder rows step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset min-w-0">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="label text-[13px] text-base-content">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class="checkbox checkbox-xs"
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset min-w-0">
      <label for={@id}>
        <span :if={@label} class="mb-0.5 block text-[11px] text-fg-secondary">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={["select select-sm h-7 min-h-0 w-full text-[13px]", @errors != [] && "select-error"]}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset min-w-0">
      <label for={@id}>
        <span :if={@label} class="mb-0.5 block text-[11px] text-fg-secondary">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            "textarea textarea-sm w-full font-mono text-[13px]",
            @errors != [] && "textarea-error"
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class="fieldset min-w-0">
      <label for={@id}>
        <span :if={@label} class="mb-0.5 block text-[11px] text-fg-secondary">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={["input input-sm h-7 min-h-0 w-full text-[13px]", @errors != [] && "input-error"]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1 flex items-center gap-1.5 text-xs text-error">
      <.icon name="hero-exclamation-circle" class="size-4" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc "Renders a table of `rows`, a column per `:col` slot and the `:action` slots in the last column."
  attr :id, :string, required: true
  attr :rows, :list, required: true

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    ~H"""
    <table class="table table-sm w-full">
      <thead>
        <tr>
          <th
            :for={col <- @col}
            class="h-8 px-4 text-[11px] font-medium tracking-wide text-fg-secondary uppercase"
          >
            {col[:label]}
          </th>
          <th :if={@action != []}>
            <span class="sr-only">Actions</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id}>
        <tr :for={row <- @rows} class="hover:bg-row-hover">
          <td :for={col <- @col} class="h-9 px-4">
            {render_slot(col, row)}
          </td>
          <td :if={@action != []} class="h-9 w-0 px-4">
            <div class="flex items-center justify-end gap-3">
              <%= for action <- @action do %>
                {render_slot(action, row)}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  @doc """
  Renders a dialog that asks before something that cannot be undone. Open it with `show_modal/1`.

  ## Examples

      <button phx-click={show_modal("confirm-delete")}>Delete</button>
      <.confirm_modal id="confirm-delete" title="Delete shop?" confirm="Delete" on_confirm={JS.push("delete")} />
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :confirm, :string, required: true, doc: "the label of the button that goes ahead"
  attr :on_confirm, JS, required: true
  slot :inner_block, doc: "what going ahead means"

  def confirm_modal(assigns) do
    ~H"""
    <%!-- LiveView must not patch away the `open` the browser sets while the dialog is shown. --%>
    <dialog id={@id} class="modal" phx-update="ignore">
      <div class="modal-box w-[360px] max-w-full whitespace-normal p-3 text-left font-normal">
        <h3 class="text-sm font-semibold">{@title}</h3>
        <p :if={@inner_block != []} class="py-2">{render_slot(@inner_block)}</p>
        <form method="dialog" class="modal-action mt-2 justify-end gap-2">
          <button class="btn btn-sm h-7 min-h-7">Cancel</button>
          <button
            id={"#{@id}-confirm"}
            class="btn btn-sm btn-error h-7 min-h-7"
            phx-click={@on_confirm}
          >
            {@confirm}
          </button>
        </form>
      </div>
      <form method="dialog" class="modal-backdrop"><button>close</button></form>
    </dialog>
    """
  end

  ## JS Commands

  @doc "Opens the dialog with this id, such as a `confirm_modal/1`."
  def show_modal(js \\ %JS{}, id), do: JS.dispatch(js, "conductor:show-modal", to: "##{id}")

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc "Interpolates the options of a form error into its message."
  def translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, msg ->
      String.replace(msg, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end
end
