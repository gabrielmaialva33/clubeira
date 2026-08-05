# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :clubeira,
  ecto_repos: [Clubeira.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

config :argon2_elixir,
  t_cost: 3,
  m_cost: 16,
  parallelism: 4

config :clubeira, Clubeira.Security.PasswordGate, max_concurrency: 8

config :clubeira, Clubeira.Redemptions.Grant, max_age_seconds: 120

config :clubeira, Clubeira.Accounts.SessionJanitor,
  enabled: true,
  initial_delay_ms: 60_000,
  interval_ms: 3_600_000,
  retention_seconds: 30 * 24 * 60 * 60

config :clubeira, Clubeira.Outbox.Worker,
  enabled: false,
  initial_delay_ms: 1_000,
  interval_ms: 1_000,
  adapter: Clubeira.Outbox.Adapters.Http,
  adapter_options: [],
  batch_size: 50,
  lock_timeout_ms: 60_000,
  max_attempts: 10,
  retry_base_ms: 1_000,
  retry_max_ms: 3_600_000

config :clubeira, ClubeiraWeb.Plugs.CredentialRateLimit,
  limiter: Clubeira.Security.LoginRateLimiter,
  limits: [
    login: [
      global: [scale_ms: 1_000, limit: 40],
      ip: [scale_ms: 60_000, limit: 20],
      identity: [scale_ms: 900_000, limit: 10]
    ],
    registration: [
      global: [scale_ms: 1_000, limit: 10],
      ip: [scale_ms: 60_000, limit: 5],
      identity: [scale_ms: 900_000, limit: 3]
    ]
  ]

# Configure the endpoint
config :clubeira, ClubeiraWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ClubeiraWeb.ErrorHTML, json: ClubeiraWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Clubeira.PubSub,
  live_view: [signing_salt: "C/SYI8LV"]

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
config :clubeira, Clubeira.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  clubeira: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  clubeira: [
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
config :phoenix, :filter_parameters, ["password", "token", "secret"]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
