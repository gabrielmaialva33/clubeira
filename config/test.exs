import Config

default_pool_size = min(System.schedulers_online() * 2, 16)

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :clubeira, Clubeira.Repo,
  username: System.get_env("CLUBEIRA_TEST_DB_USER", "postgres"),
  password: System.get_env("CLUBEIRA_TEST_DB_PASSWORD", "postgres"),
  hostname: System.get_env("CLUBEIRA_TEST_DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("CLUBEIRA_TEST_DB_PORT", "55432")),
  database: "clubeira_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size:
    System.get_env("CLUBEIRA_TEST_DB_POOL_SIZE", Integer.to_string(default_pool_size))
    |> String.to_integer()

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :clubeira, ClubeiraWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: String.duplicate("test-only-", 8),
  server: false

# In test we don't send emails
config :clubeira, Clubeira.Mailer, adapter: Swoosh.Adapters.Test

# Keep password hashing semantics while making the test suite fast.
config :argon2_elixir, t_cost: 1, m_cost: 8, parallelism: 1

config :clubeira, Clubeira.Security.PasswordGate, max_concurrency: 2

config :clubeira, Clubeira.Security.IdentifierVault,
  active_key_version: 1,
  encryption_keys: %{1 => :crypto.hash(:sha256, "test identifier encryption key")},
  lookup_key: :crypto.hash(:sha256, "test identifier lookup key")

config :clubeira, Clubeira.Accounts.SessionJanitor, enabled: false

config :clubeira, ClubeiraWeb.Plugs.CredentialRateLimit,
  limiter: Clubeira.Security.LoginRateLimiter,
  limits: [
    login: [
      global: [scale_ms: 1_000, limit: 10_000],
      ip: [scale_ms: 60_000, limit: 10_000],
      identity: [scale_ms: 900_000, limit: 10_000]
    ],
    registration: [
      global: [scale_ms: 1_000, limit: 10_000],
      ip: [scale_ms: 60_000, limit: 10_000],
      identity: [scale_ms: 900_000, limit: 10_000]
    ],
    email_verification_request: [
      global: [scale_ms: 1_000, limit: 10_000],
      ip: [scale_ms: 60_000, limit: 10_000],
      identity: [scale_ms: 900_000, limit: 10_000]
    ],
    email_verification: [
      global: [scale_ms: 1_000, limit: 10_000],
      ip: [scale_ms: 60_000, limit: 10_000],
      identity: [scale_ms: 900_000, limit: 10_000]
    ],
    password_reset_request: [
      global: [scale_ms: 1_000, limit: 10_000],
      ip: [scale_ms: 60_000, limit: 10_000],
      identity: [scale_ms: 900_000, limit: 10_000]
    ],
    password_reset: [
      global: [scale_ms: 1_000, limit: 10_000],
      ip: [scale_ms: 60_000, limit: 10_000],
      identity: [scale_ms: 900_000, limit: 10_000]
    ]
  ]

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

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
