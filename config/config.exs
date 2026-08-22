# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :mister,
  ecto_repos: [Mister.Repo],
  generators: [timestamp_type: :utc_datetime],
  base_url: "https://mister.mundodeportivo.com",
  # Regla de puja máxima de la liga: saldo + 25% del valor del equipo
  # (:balance_plus_25 | :balance_only | :balance_plus_50 | :unlimited)
  bid_rule: :balance_plus_25,
  # Token de larga vida capturado en el login manual (Sign in with Apple).
  # Nunca en el repo: se inyecta vía env/secreto en runtime.exs.
  refresh_token: nil

# Jobs programados: análisis diario a las 7am (hora española)
config :mister, Oban,
  engine: Oban.Engines.Basic,
  repo: Mister.Repo,
  queues: [mister: 1],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"0 7 * * *", Mister.Workers.DailyAnalysis}
     ],
     timezone: "Europe/Madrid"},
    Oban.Plugins.Pruner
  ]

# Configure the endpoint
config :mister, MisterWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: MisterWeb.ErrorHTML, json: MisterWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Mister.PubSub,
  live_view: [signing_salt: "tlxKsrAx"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :mister, Mister.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  mister: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  mister: [
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

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
