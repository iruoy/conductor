import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :conductor, Conductor.Repo,
  database: Path.expand("../conductor_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :conductor, ConductorWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Ms8H53EOgIe4cF+wQIWl/QXRBOGBPdlwQzlp/5UoUoW8cYoa+xvgPGJDAxFwAZdp",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Tests start the runner (a fake one), Coordinator and Poller themselves.
config :conductor, :start_workers, false

config :conductor, Conductor.Runner,
  executable: "elixir",
  args: [Path.expand("../test/support/fake_runner.exs", __DIR__)],
  cd: Path.expand("..", __DIR__)

config :conductor, Conductor.Poller, interval: nil

config :conductor, Conductor.GitHub,
  token: "gh-token",
  req_options: [plug: {Req.Test, Conductor.GitHub}, retry: false]
