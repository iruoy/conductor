import Config

# Postgrex requires socket_dir rather than hostname for Unix-socket connections.
pg_host = System.get_env("PGHOST") || "localhost"

config :conductor,
       Conductor.Repo,
       if(Path.type(pg_host) == :absolute, do: [socket_dir: pg_host], else: [hostname: pg_host])

# Configure your database
config :conductor, Conductor.Repo,
  username: System.get_env("PGUSER") || "postgres",
  password: System.get_env("PGPASSWORD") || "postgres",
  port: String.to_integer(System.get_env("PGPORT") || "5432"),
  database: "conductor_dev",
  pool_size: 10,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

config :conductor, ConductorWeb.Endpoint,
  # Binding to loopback ipv4 address prevents access from other machines.
  # Change to `ip: {0, 0, 0, 0}` to allow access from other machines.
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "LvSgMkCo4bySmR0rWaZApSOto4HkhquEIjG4Qucb2j7O5XdfInSyyZfd39gcTj0+",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:conductor, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:conductor, ~w(--watch)]}
  ]

# Reload browser tabs when matching files change.
config :conductor, ConductorWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/.*\.(js|css)$"E,
      ~r"lib/conductor_web/router\.ex$"E,
      ~r"lib/conductor_web/(controllers|live|components)/.*\.(ex|heex)$"E
    ]
  ]

# Do not include metadata nor timestamps in development logs
config :logger, :default_formatter, format: "[$level] $message\n"

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  # Include debug annotations and locations in rendered markup.
  # Changing this configuration will require mix clean and a full recompile.
  debug_heex_annotations: true,
  debug_attributes: true,
  # Enable helpful, but potentially expensive runtime checks
  enable_expensive_runtime_checks: true
