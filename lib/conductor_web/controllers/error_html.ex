defmodule ConductorWeb.ErrorHTML do
  @moduledoc "Error pages: the status message as plain text, such as \"Not Found\" for a 404."
  use ConductorWeb, :html

  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end
