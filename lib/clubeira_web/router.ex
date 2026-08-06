defmodule ClubeiraWeb.Router do
  use ClubeiraWeb, :router

  @secure_headers %{
    "content-security-policy" =>
      "default-src 'self'; base-uri 'self'; object-src 'none'; frame-ancestors 'none'; " <>
        "form-action 'self'; img-src 'self' data:; font-src 'self' data:; " <>
        "style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self'"
  }

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ClubeiraWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, @secure_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :put_secure_browser_headers, @secure_headers
  end

  pipeline :authenticated_api do
    plug ClubeiraWeb.Plugs.ApiAuth
  end

  pipeline :login_api do
    plug ClubeiraWeb.Plugs.CredentialRateLimit, action: :login
  end

  pipeline :registration_api do
    plug ClubeiraWeb.Plugs.CredentialRateLimit, action: :registration
  end

  pipeline :password_reset_request_api do
    plug ClubeiraWeb.Plugs.CredentialRateLimit, action: :password_reset_request
  end

  pipeline :password_reset_api do
    plug ClubeiraWeb.Plugs.CredentialRateLimit, action: :password_reset
  end

  pipeline :email_verification_api do
    plug ClubeiraWeb.Plugs.CredentialRateLimit, action: :email_verification
  end

  pipeline :email_verification_request_api do
    plug ClubeiraWeb.Plugs.CredentialRateLimit, action: :email_verification_request
  end

  scope "/", ClubeiraWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/", ClubeiraWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end

  scope "/api/v1", ClubeiraWeb do
    pipe_through [:api, :login_api]

    post "/auth/sessions", AuthSessionController, :create
  end

  scope "/api/v1", ClubeiraWeb do
    pipe_through [:api, :registration_api]

    post "/auth/registrations", RegistrationController, :create
  end

  scope "/api/v1", ClubeiraWeb do
    pipe_through [:api, :password_reset_request_api]

    post "/auth/password-reset-requests", PasswordResetRequestController, :create
  end

  scope "/api/v1", ClubeiraWeb do
    pipe_through [:api, :password_reset_api]

    post "/auth/password-resets", PasswordResetController, :create
  end

  scope "/api/v1", ClubeiraWeb do
    pipe_through [:api, :email_verification_api]

    post "/auth/email-verifications", EmailVerificationController, :create
  end

  scope "/api/v1", ClubeiraWeb do
    pipe_through [:api, :authenticated_api, :email_verification_request_api]

    post "/auth/email-verification-requests", EmailVerificationRequestController, :create
  end

  scope "/api/v1", ClubeiraWeb do
    pipe_through :api

    get "/polos/:polo_slug/catalog", CatalogController, :show
    get "/polos/:polo_slug/checkout-options", CatalogController, :checkout_options
    get "/polos/:polo_slug/places", PlaceController, :index
    get "/polos/:polo_slug/places/:place_id/reviews", ReviewController, :index
    get "/legal/registration", LegalController, :registration
    post "/polos/:polo_slug/redemptions", RedemptionConfirmationController, :create
    post "/webhooks/mercado-pago/:merchant_account_id", PaymentWebhookController, :mercado_pago
  end

  scope "/api/v1", ClubeiraWeb do
    pipe_through [:api, :authenticated_api]

    delete "/auth/session", AuthSessionController, :delete
    get "/me", AccountController, :show
    get "/me/subscriptions", SubscriptionController, :index
    post "/polos/:polo_slug/orders", CheckoutController, :create
    post "/polos/:polo_slug/orders/:order_id/payment-intents", PaymentIntentController, :create
    post "/polos/:polo_slug/me/redemption-devices", RedemptionDeviceController, :create
    post "/polos/:polo_slug/me/redemption-grants", RedemptionGrantController, :create
    post "/polos/:polo_slug/places/:place_id/reviews", ReviewController, :create
    post "/polos/:polo_slug/backoffice/partners", BackofficePartnerController, :create

    put "/polos/:polo_slug/backoffice/places/:place_id/profile",
        BackofficePlaceProfileController,
        :update

    post "/polos/:polo_slug/backoffice/places/:place_id/benefit-offers",
         BackofficeBenefitOfferController,
         :create

    post "/polos/:polo_slug/backoffice/product-offerings",
         BackofficeProductOfferingController,
         :create

    post "/polos/:polo_slug/backoffice/product-offerings/:product_offering_id/lifecycle-actions",
         BackofficeProductOfferingLifecycleController,
         :create

    get "/polos/:polo_slug/backoffice/payments", BackofficePaymentController, :index

    post "/polos/:polo_slug/backoffice/payments/:payment_id/refunds",
         BackofficePaymentRefundController,
         :create

    get "/polos/:polo_slug/backoffice/validation-points",
        BackofficeValidationPointController,
        :index

    post "/polos/:polo_slug/backoffice/places/:place_id/validation-points",
         BackofficeValidationPointController,
         :create

    post "/polos/:polo_slug/backoffice/validation-points/:validation_point_id/lifecycle-actions",
         BackofficeValidationPointLifecycleController,
         :create

    post "/polos/:polo_slug/backoffice/validation-credentials/:credential_id/rotations",
         BackofficeValidationCredentialRotationController,
         :create

    post "/polos/:polo_slug/backoffice/validation-credentials/:credential_id/revocations",
         BackofficeValidationCredentialRevocationController,
         :create

    get "/polos/:polo_slug/backoffice/reviews", BackofficeReviewController, :index

    post "/polos/:polo_slug/backoffice/reviews/:review_id/moderation-actions",
         BackofficeReviewController,
         :create_action

    get "/polos/:polo_slug/me/orders", OrderController, :index
    get "/polos/:polo_slug/me/redemptions", RedemptionController, :index
    get "/polos/:polo_slug/me/vouchers", WalletController, :index
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:clubeira, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ClubeiraWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
