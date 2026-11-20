# Keep the developer's git config (signing, hooks, aliases) out of the tests' git repositories.
System.put_env(%{"GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1"})

# Shutting down a test's workers kills any job that is mid-query, and its connection logs that the client exited.
# That happens after the test, outside its captured log, so drop just that message.
:logger.add_primary_filter(:test_teardown_disconnects, {
  fn
    %{msg: {:string, message}} = event, _ ->
      if IO.chardata_to_string(message) =~ ~r/disconnected: .*client #PID<[\d.]+> exited$/,
        do: :stop,
        else: event

    event, _ ->
      event
  end,
  nil
})

ExUnit.start(capture_log: true)
Ecto.Adapters.SQL.Sandbox.mode(Conductor.Repo, :manual)
