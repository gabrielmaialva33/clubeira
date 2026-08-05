import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/clubeira start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :clubeira, ClubeiraWeb.Endpoint, server: true
end

config :clubeira, ClubeiraWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if mercado_pago_accounts = System.get_env("MERCADO_PAGO_ACCOUNTS_JSON") do
  config :clubeira, Clubeira.Billing.Gateways.MercadoPago,
    accounts:
      Clubeira.Billing.Gateways.MercadoPago.Configuration.parse_accounts!(mercado_pago_accounts)
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :clubeira, ClubeiraWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/clubeira_web/router\.ex$"E,
        ~r"lib/clubeira_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  integer_in_range! = fn name, default, range ->
    value = System.get_env(name, Integer.to_string(default))

    case Integer.parse(value) do
      {parsed, ""} ->
        if parsed in range do
          parsed
        else
          raise "#{name} must be an integer in #{inspect(range)}, got: #{inspect(value)}"
        end

      _invalid ->
        raise "#{name} must be an integer in #{inspect(range)}, got: #{inspect(value)}"
    end
  end

  boolean! = fn name, default ->
    case System.get_env(name, to_string(default)) |> String.downcase() do
      value when value in ["true", "1"] -> true
      value when value in ["false", "0"] -> false
      value -> raise "#{name} must be true, false, 1, or 0, got: #{inspect(value)}"
    end
  end

  required_env! = fn name ->
    case System.fetch_env(name) do
      {:ok, value} when value != "" -> value
      _missing -> raise "environment variable #{name} is required"
    end
  end

  config :argon2_elixir,
    t_cost: integer_in_range!.("ARGON2_T_COST", 3, 2..10),
    m_cost: integer_in_range!.("ARGON2_M_COST", 16, 16..20),
    parallelism: integer_in_range!.("ARGON2_PARALLELISM", 4, 1..16)

  config :clubeira, Clubeira.Security.PasswordGate,
    max_concurrency: integer_in_range!.("ARGON2_MAX_CONCURRENCY", 8, 1..64)

  config :clubeira, Clubeira.Redemptions.Grant,
    max_age_seconds: integer_in_range!.("REDEMPTION_GRANT_MAX_AGE_SECONDS", 120, 30..600)

  config :clubeira, ClubeiraWeb.Plugs.CredentialRateLimit,
    limiter: Clubeira.Security.LoginRateLimiter,
    limits: [
      login: [
        global: [
          scale_ms: 1_000,
          limit: integer_in_range!.("LOGIN_RATE_GLOBAL_PER_SECOND", 40, 1..10_000)
        ],
        ip: [
          scale_ms: 60_000,
          limit: integer_in_range!.("LOGIN_RATE_IP_PER_MINUTE", 20, 1..10_000)
        ],
        identity: [
          scale_ms: 900_000,
          limit: integer_in_range!.("LOGIN_RATE_IDENTITY_PER_15_MINUTES", 10, 1..10_000)
        ]
      ],
      registration: [
        global: [
          scale_ms: 1_000,
          limit: integer_in_range!.("REGISTRATION_RATE_GLOBAL_PER_SECOND", 10, 1..10_000)
        ],
        ip: [
          scale_ms: 60_000,
          limit: integer_in_range!.("REGISTRATION_RATE_IP_PER_MINUTE", 5, 1..10_000)
        ],
        identity: [
          scale_ms: 900_000,
          limit: integer_in_range!.("REGISTRATION_RATE_IDENTITY_PER_15_MINUTES", 3, 1..10_000)
        ]
      ],
      password_reset_request: [
        global: [
          scale_ms: 1_000,
          limit: integer_in_range!.("PASSWORD_RESET_RATE_GLOBAL_PER_SECOND", 20, 1..10_000)
        ],
        ip: [
          scale_ms: 60_000,
          limit: integer_in_range!.("PASSWORD_RESET_RATE_IP_PER_MINUTE", 10, 1..10_000)
        ],
        identity: [
          scale_ms: 900_000,
          limit:
            integer_in_range!.(
              "PASSWORD_RESET_RATE_IDENTITY_PER_15_MINUTES",
              3,
              1..10_000
            )
        ]
      ],
      password_reset: [
        global: [
          scale_ms: 1_000,
          limit:
            integer_in_range!.("PASSWORD_RESET_CONFIRM_RATE_GLOBAL_PER_SECOND", 40, 1..10_000)
        ],
        ip: [
          scale_ms: 60_000,
          limit: integer_in_range!.("PASSWORD_RESET_CONFIRM_RATE_IP_PER_MINUTE", 20, 1..10_000)
        ],
        identity: [
          scale_ms: 900_000,
          limit:
            integer_in_range!.(
              "PASSWORD_RESET_CONFIRM_RATE_TOKEN_PER_15_MINUTES",
              10,
              1..10_000
            )
        ]
      ]
    ]

  password_reset_url = required_env!.("PASSWORD_RESET_URL")

  unless match?(
           {:ok, %URI{scheme: "https", host: host, userinfo: nil, fragment: nil}}
           when is_binary(host) and host != "",
           URI.new(password_reset_url)
         ) do
    raise "PASSWORD_RESET_URL must be an absolute HTTPS URL without credentials or a fragment"
  end

  config :clubeira, Clubeira.Accounts.PasswordRecovery,
    token_ttl_seconds: integer_in_range!.("PASSWORD_RESET_TOKEN_TTL_MINUTES", 30, 5..120) * 60,
    reset_url: password_reset_url,
    from: {"Clubeira", required_env!.("PASSWORD_RESET_FROM_EMAIL")}

  retention_days = integer_in_range!.("SESSION_RETENTION_DAYS", 30, 1..365)

  config :clubeira, Clubeira.Accounts.SessionJanitor,
    enabled: true,
    initial_delay_ms: 60_000,
    interval_ms: 3_600_000,
    retention_seconds: retention_days * 24 * 60 * 60

  if boolean!.("OUTBOX_PUBLISHER_ENABLED", false) do
    url = required_env!.("OUTBOX_WEBHOOK_URL")
    secret = required_env!.("OUTBOX_WEBHOOK_SECRET")

    unless match?(
             {:ok, %URI{scheme: "https", host: host, userinfo: nil, fragment: nil}}
             when is_binary(host) and host != "",
             URI.new(url)
           ) do
      raise "OUTBOX_WEBHOOK_URL must be an absolute HTTPS URL without credentials or a fragment"
    end

    if byte_size(secret) < 32 do
      raise "OUTBOX_WEBHOOK_SECRET must contain at least 32 bytes"
    end

    retry_base_ms =
      integer_in_range!.("OUTBOX_RETRY_BASE_MS", 1_000, 100..600_000)

    retry_max_ms =
      integer_in_range!.("OUTBOX_RETRY_MAX_MS", 3_600_000, 1_000..86_400_000)

    if retry_max_ms < retry_base_ms do
      raise "OUTBOX_RETRY_MAX_MS must be greater than or equal to OUTBOX_RETRY_BASE_MS"
    end

    config :clubeira, Clubeira.Outbox.Worker,
      enabled: true,
      initial_delay_ms: integer_in_range!.("OUTBOX_INITIAL_DELAY_MS", 1_000, 100..60_000),
      interval_ms: integer_in_range!.("OUTBOX_INTERVAL_MS", 1_000, 100..60_000),
      adapter: Clubeira.Outbox.Adapters.Http,
      adapter_options: [
        url: url,
        secret: secret,
        receive_timeout: integer_in_range!.("OUTBOX_HTTP_TIMEOUT_MS", 10_000, 100..120_000)
      ],
      batch_size: integer_in_range!.("OUTBOX_BATCH_SIZE", 50, 1..1_000),
      lock_timeout_ms: integer_in_range!.("OUTBOX_LOCK_TIMEOUT_MS", 60_000, 1_000..600_000),
      max_attempts: integer_in_range!.("OUTBOX_MAX_ATTEMPTS", 10, 1..100),
      retry_base_ms: retry_base_ms,
      retry_max_ms: retry_max_ms
  end

  database_role_mode = System.get_env("CLUBEIRA_DATABASE_ROLE_MODE", "runtime")

  {database_url, database_role_options} =
    case database_role_mode do
      "runtime" ->
        url =
          System.get_env("DATABASE_URL") ||
            raise """
            environment variable DATABASE_URL is missing for the runtime role.
            It must use a NOSUPERUSER NOBYPASSRLS PostgreSQL login.
            """

        {url, after_connect: {Clubeira.Repo.RuntimeRole, :validate_connection!, []}}

      "migrator" ->
        url =
          System.get_env("MIGRATOR_DATABASE_URL") ||
            raise """
            environment variable MIGRATOR_DATABASE_URL is missing in migrator mode.
            """

        {url, []}

      invalid ->
        raise """
        invalid CLUBEIRA_DATABASE_ROLE_MODE=#{inspect(invalid)}; expected runtime or migrator
        """
    end

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  repo_options = [
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6
  ]

  config :clubeira, Clubeira.Repo, repo_options ++ database_role_options

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :clubeira, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :clubeira, ClubeiraWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :clubeira, ClubeiraWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :clubeira, ClubeiraWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :clubeira, Clubeira.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
