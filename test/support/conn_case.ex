defmodule ConductorWeb.ConnCase do
  @moduledoc "Tests through the endpoint, with a sandboxed database like `Conductor.DataCase`."

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint ConductorWeb.Endpoint

      use ConductorWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import ConductorWeb.ConnCase
    end
  end

  setup tags do
    Conductor.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
