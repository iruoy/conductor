[
  import_deps: [
    :ecto,
    :ecto_sql,
    :phoenix,
    :ash,
    :ash_postgres,
    :ash_phoenix,
    :ash_state_machine,
    :ash_paper_trail
  ],
  subdirectories: ["priv/*/migrations"],
  plugins: [Phoenix.LiveView.HTMLFormatter, Spark.Formatter],
  inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}", "priv/*/seeds.exs"]
]
