# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :conductor,
  ecto_repos: [Conductor.Repo],
  ash_domains: [Conductor.Config, Conductor.Runs],
  generators: [timestamp_type: :utc_datetime]

# Opt into the recommended Ash defaults for the next major version.
config :ash,
  allow_forbidden_field_for_relationships_by_default: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true,
  redact_sensitive_values_in_errors?: true,
  default_string_length_count: :codepoints,
  infer_generic_action_reactors?: false,
  many_to_many_destroy_destination_on_match?: true,
  default_belongs_to_type: :uuid,
  known_types: [AshPostgres.Timestamptz, AshPostgres.TimestamptzUsec]

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :postgres,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [section_order: [:resources, :policies, :authorization, :domain, :execution]]
  ]

config :conductor, Conductor.Runner,
  executable: "node",
  # Node runs the TypeScript sources itself (type stripping); `pnpm typecheck` checks them.
  args: [Path.expand("../runner/src/main.ts", __DIR__)],
  cd: Path.expand("../runner", __DIR__)

config :conductor, Conductor.Poller, interval: 60_000

# Configure the endpoint
config :conductor, ConductorWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ConductorWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: Conductor.PubSub,
  live_view: [signing_salt: "TSV6iDde"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.28.2",
  conductor: [
    args:
      ~w(js/app.js --bundle --target=es2025 --outdir=../priv/static/assets/js --external:/fonts/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.5",
  conductor: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, JSON

# syntect highlights every language without a native Makeup lexer (see ConductorWeb.CodeHighlight), Erlang included.
config :makeup_syntect, excluded_languages: ["elixir", "html_eex"]

import_config "#{config_env()}.exs"
