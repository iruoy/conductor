import Config

if config_env() == :dev do
  # Export sourced values so the Node runner inherits them as well.
  Dotenvy.source!([Path.expand("../.env", __DIR__), System.get_env()])
  |> System.put_env()
end

# Releases start the endpoint only with PHX_SERVER=true.
if System.get_env("PHX_SERVER") do
  config :conductor, ConductorWeb.Endpoint, server: true
end

config :conductor, ConductorWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() != :test do
  config :conductor, Conductor.GitHub, token: System.get_env("GITHUB_TOKEN")

  config :conductor,
    workspace_root: System.get_env("CONDUCTOR_WORKSPACES", "~/conductor-workspaces")

  if dir = System.get_env("CONDUCTOR_RUNNER_DATA") do
    config :conductor, Conductor.Runner, env: [{"CONDUCTOR_RUNNER_DATA", dir}]
  end
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :conductor, Conductor.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :conductor, ConductorWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base
end
