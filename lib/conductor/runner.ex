defmodule Conductor.Runner do
  @moduledoc """
  Owns the Node runner as an Erlang Port speaking JSON lines over stdio.

  `call/2` sends a command and waits for its reply. Events go to `Conductor.Runs.ingest/1`; `ready`, `run_state` and
  `run_settled` are also forwarded to `Conductor.Coordinator`. When the runner exits, this process stops so its
  supervisor restarts it, and with it the Coordinator, which reconciles against the fresh runner.

  Configure with `config :conductor, Conductor.Runner, executable: "node", args: [...], env: [...]`.
  """
  use GenServer
  require Logger
  alias Conductor.Runs

  @forward ~w(ready run_state run_settled)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Sends a command (a map with a `type`) and returns `{:ok, result}` or `{:error, reason}`."
  def call(command, timeout \\ 60_000) do
    GenServer.call(__MODULE__, {:command, command}, timeout)
  catch
    :exit, {reason, _} -> {:error, {:runner_unavailable, reason}}
  end

  @doc "The OS pid of the runner process."
  def os_pid, do: GenServer.call(__MODULE__, :os_pid)

  @impl true
  def init(opts) do
    config = Keyword.merge(Application.get_env(:conductor, __MODULE__, []), opts)
    executable = Keyword.fetch!(config, :executable)

    path =
      System.find_executable(executable) || (File.exists?(executable) && executable) ||
        raise "runner executable #{executable} not found"

    port =
      Port.open({:spawn_executable, path}, [
        :binary,
        :exit_status,
        {:line, 1_048_576},
        args: Keyword.get(config, :args, []),
        env: for({k, v} <- Keyword.get(config, :env, []), do: {to_charlist(k), to_charlist(v)}),
        cd: Keyword.get(config, :cd, File.cwd!())
      ])

    {:ok,
     %{
       port: port,
       pending: %{},
       next_id: 1,
       buffer: [],
       forward_to: Keyword.get(config, :forward_to)
     }}
  end

  @impl true
  def handle_call({:command, command}, from, state) do
    id = state.next_id

    line =
      command
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("id", id)
      |> Jason.encode!()

    Port.command(state.port, [line, ?\n])
    {:noreply, %{state | pending: Map.put(state.pending, id, from), next_id: id + 1}}
  end

  def handle_call(:os_pid, _from, state) do
    {:reply, Port.info(state.port, :os_pid) |> elem(1), state}
  end

  @impl true
  def handle_info({port, {:data, {:noeol, part}}}, %{port: port} = state) do
    {:noreply, %{state | buffer: [state.buffer | part]}}
  end

  def handle_info({port, {:data, {:eol, part}}}, %{port: port} = state) do
    line = IO.iodata_to_binary([state.buffer | part])
    state = %{state | buffer: []}

    case Jason.decode(line) do
      {:ok, message} ->
        {:noreply, handle_message(message, state)}

      {:error, _} ->
        {:noreply,
         tap(state, fn _ -> Logger.warning("runner: unparseable line #{inspect(line)}") end)}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("runner exited with status #{status}")
    for {_id, from} <- state.pending, do: GenServer.reply(from, {:error, :runner_exited})
    {:stop, {:runner_exited, status}, %{state | pending: %{}}}
  end

  @impl true
  def terminate(_reason, %{port: port}) do
    # Closing stdin makes the runner exit; it keeps its durable state for the next start.
    if Port.info(port), do: Port.close(port)
  catch
    _, _ -> :ok
  end

  defp handle_message(%{"type" => "reply", "id" => id} = reply, state) do
    {from, pending} = Map.pop(state.pending, id)

    if from do
      GenServer.reply(
        from,
        if(reply["ok"], do: {:ok, reply["result"]}, else: {:error, reply["error"]})
      )
    end

    %{state | pending: pending}
  end

  defp handle_message(%{"type" => "log"} = log, state) do
    Logger.log(if(log["level"] == "error", do: :error, else: :info), "runner: #{log["message"]}")
    state
  end

  defp handle_message(%{"type" => type} = event, state) do
    try do
      Runs.ingest(event)
    rescue
      error ->
        Logger.error("runner event #{type}: #{Exception.format(:error, error, __STACKTRACE__)}")
    end

    # The Coordinator may not be up yet after a restart; it syncs on start, so a dropped event is fine.
    with true <- type in @forward,
         dest when dest != nil <- state.forward_to || Process.whereis(Conductor.Coordinator) do
      send(dest, {:runner, event})
    end

    state
  end
end
