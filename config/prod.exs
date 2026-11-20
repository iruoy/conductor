import Config

# `mix assets.deploy` writes the manifest of digested static files.
config :conductor, ConductorWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

# HTTPS only (with HSTS), except on localhost. `:force_ssl` must be set at compile time.
config :conductor, ConductorWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [hosts: ["localhost", "127.0.0.1"]]
  ]

# Do not print debug messages in production
config :logger, level: :info
