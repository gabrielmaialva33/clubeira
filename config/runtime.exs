import Config

gateway_options =
  case System.get_env("CLUBEIRA_PIX_PROVIDER") do
    nil ->
      []

    _configured ->
      [
        payment_providers: %{
          "pix" => Clubeira.RuntimeConfig.provider_code!("CLUBEIRA_PIX_PROVIDER")
        }
      ]
  end

gateway_options =
  case System.get_env("CLUBEIRA_SUBSCRIPTION_PROVIDER") do
    nil ->
      gateway_options

    _configured ->
      Keyword.put(
        gateway_options,
        :subscription_provider,
        Clubeira.RuntimeConfig.provider_code!("CLUBEIRA_SUBSCRIPTION_PROVIDER")
      )
  end

if gateway_options != [] do
  config :clubeira, Clubeira.Billing.Gateways, gateway_options
end

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
if config_env() != :prod do
  if System.get_env("PHX_SERVER") do
    config :clubeira, ClubeiraWeb.Endpoint, server: true
  end

  config :clubeira, ClubeiraWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4000"))]
end

mercado_pago_options =
  case System.get_env("MERCADO_PAGO_ACCOUNTS_JSON") do
    nil ->
      []

    mercado_pago_accounts ->
      [
        accounts:
          Clubeira.Billing.Gateways.MercadoPago.Configuration.parse_accounts!(
            mercado_pago_accounts
          )
      ]
  end

mercado_pago_options =
  case System.get_env("MERCADO_PAGO_SUBSCRIPTION_BACK_URL") do
    nil ->
      mercado_pago_options

    _configured ->
      Keyword.put(
        mercado_pago_options,
        :subscription_back_url,
        Clubeira.RuntimeConfig.absolute_https_url!("MERCADO_PAGO_SUBSCRIPTION_BACK_URL")
      )
  end

if mercado_pago_options != [] do
  config :clubeira, Clubeira.Billing.Gateways.MercadoPago, mercado_pago_options
end

if System.get_env("PLATFORM_BILLING_MERCHANT_ACCOUNT_ID") do
  config :clubeira, :platform_billing,
    merchant_account_id: Clubeira.RuntimeConfig.uuid!("PLATFORM_BILLING_MERCHANT_ACCOUNT_ID")
end

review_media_environment =
  ~w(
    REVIEW_MEDIA_VERIFICATION_URL
    REVIEW_MEDIA_PUBLIC_BASE_URL
    REVIEW_MEDIA_VERIFICATION_BEARER_TOKEN
  )

if Enum.any?(review_media_environment, &System.get_env/1) do
  review_media_options = [
    verification_url: Clubeira.RuntimeConfig.absolute_https_url!("REVIEW_MEDIA_VERIFICATION_URL"),
    public_base_url: Clubeira.RuntimeConfig.absolute_https_url!("REVIEW_MEDIA_PUBLIC_BASE_URL")
  ]

  review_media_options =
    case System.get_env("REVIEW_MEDIA_VERIFICATION_BEARER_TOKEN") do
      nil ->
        review_media_options

      _configured ->
        Keyword.put(
          review_media_options,
          :bearer_token,
          Clubeira.RuntimeConfig.required_env!("REVIEW_MEDIA_VERIFICATION_BEARER_TOKEN")
        )
    end

  config :clubeira, Clubeira.Reviews.MediaVerifiers.Http, review_media_options
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
  integer_in_range! = &Clubeira.RuntimeConfig.integer_in_range!/3
  boolean! = &Clubeira.RuntimeConfig.boolean!/2
  required_env! = &Clubeira.RuntimeConfig.required_env!/1
  base64url_key! = &Clubeira.RuntimeConfig.base64url_key!/1

  database_role_mode = System.get_env("CLUBEIRA_DATABASE_ROLE_MODE", "runtime")

  role_mode =
    case database_role_mode do
      "runtime" ->
        :runtime

      "migrator" ->
        :migrator

      invalid ->
        raise "invalid CLUBEIRA_DATABASE_ROLE_MODE=#{inspect(invalid)}; expected runtime or migrator"
    end

  server? = boolean!.("PHX_SERVER", false)

  if role_mode == :migrator and server? do
    raise "PHX_SERVER cannot be enabled when CLUBEIRA_DATABASE_ROLE_MODE=migrator"
  end

  config :clubeira, :database_role_mode, role_mode

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
      email_verification_request: [
        global: [
          scale_ms: 1_000,
          limit: integer_in_range!.("EMAIL_VERIFICATION_RATE_GLOBAL_PER_SECOND", 20, 1..10_000)
        ],
        ip: [
          scale_ms: 60_000,
          limit: integer_in_range!.("EMAIL_VERIFICATION_RATE_IP_PER_MINUTE", 10, 1..10_000)
        ],
        identity: [
          scale_ms: 900_000,
          limit:
            integer_in_range!.(
              "EMAIL_VERIFICATION_RATE_IDENTITY_PER_15_MINUTES",
              3,
              1..10_000
            )
        ]
      ],
      email_verification: [
        global: [
          scale_ms: 1_000,
          limit:
            integer_in_range!.(
              "EMAIL_VERIFICATION_CONFIRM_RATE_GLOBAL_PER_SECOND",
              40,
              1..10_000
            )
        ],
        ip: [
          scale_ms: 60_000,
          limit:
            integer_in_range!.(
              "EMAIL_VERIFICATION_CONFIRM_RATE_IP_PER_MINUTE",
              20,
              1..10_000
            )
        ],
        identity: [
          scale_ms: 900_000,
          limit:
            integer_in_range!.(
              "EMAIL_VERIFICATION_CONFIRM_RATE_TOKEN_PER_15_MINUTES",
              10,
              1..10_000
            )
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

  if database_role_mode == "runtime" do
    identifier_key_version =
      integer_in_range!.("IDENTIFIER_ENCRYPTION_KEY_VERSION", 1, 1..32_767)

    config :clubeira, Clubeira.Security.IdentifierVault,
      active_key_version: identifier_key_version,
      encryption_keys: %{
        identifier_key_version => base64url_key!.("IDENTIFIER_ENCRYPTION_KEY_BASE64")
      },
      lookup_key: base64url_key!.("IDENTIFIER_LOOKUP_KEY_BASE64")

    password_reset_url = Clubeira.RuntimeConfig.absolute_https_url!("PASSWORD_RESET_URL")
    email_verification_url = Clubeira.RuntimeConfig.absolute_https_url!("EMAIL_VERIFICATION_URL")
    mailer_from_email = Clubeira.RuntimeConfig.email!("MAILER_FROM_EMAIL")

    config :clubeira, Clubeira.Accounts.PasswordRecovery,
      token_ttl_seconds: integer_in_range!.("PASSWORD_RESET_TOKEN_TTL_MINUTES", 30, 5..120) * 60,
      reset_url: password_reset_url,
      from: {"Clubeira", mailer_from_email}

    config :clubeira, Clubeira.Accounts.EmailVerification,
      token_ttl_seconds:
        integer_in_range!.("EMAIL_VERIFICATION_TOKEN_TTL_HOURS", 24, 1..168) * 60 * 60,
      verification_url: email_verification_url,
      from: {"Clubeira", mailer_from_email}

    case required_env!.("MAILER_PROVIDER") do
      "resend" ->
        config :clubeira, Clubeira.Mailer,
          adapter: Swoosh.Adapters.Resend,
          api_key: required_env!.("RESEND_API_KEY")

      provider ->
        raise "MAILER_PROVIDER must be resend, got: #{inspect(provider)}"
    end
  end

  retention_days = integer_in_range!.("SESSION_RETENTION_DAYS", 30, 1..365)

  config :clubeira, Clubeira.Accounts.SessionJanitor,
    enabled: role_mode == :runtime,
    initial_delay_ms: 60_000,
    interval_ms: 3_600_000,
    retention_seconds: retention_days * 24 * 60 * 60

  if role_mode == :runtime and boolean!.("OUTBOX_PUBLISHER_ENABLED", false) do
    url = Clubeira.RuntimeConfig.absolute_https_url!("OUTBOX_WEBHOOK_URL")
    secret = required_env!.("OUTBOX_WEBHOOK_SECRET")

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
    ssl: Clubeira.RuntimeConfig.database_ssl!(),
    url: database_url,
    pool_size: integer_in_range!.("POOL_SIZE", 10, 1..100),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6
  ]

  config :clubeira, Clubeira.Repo, repo_options ++ database_role_options

  if role_mode == :runtime do
    secret_key_base = required_env!.("SECRET_KEY_BASE")
    host = Clubeira.RuntimeConfig.host!("PHX_HOST")

    config :clubeira, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

    config :clubeira, ClubeiraWeb.Endpoint,
      server: server?,
      url: [host: host, port: 443, scheme: "https"],
      http: [
        # Bind on all IPv4 and IPv6 interfaces. TLS terminates at the proxy.
        ip: {0, 0, 0, 0, 0, 0, 0, 0},
        port: integer_in_range!.("PORT", 4000, 1..65_535)
      ],
      secret_key_base: secret_key_base
  end

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
end
