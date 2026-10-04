# Keep the developer's git config (signing, hooks, aliases) out of the tests' git repositories.
System.put_env(%{"GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1"})

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Conductor.Repo, :manual)
