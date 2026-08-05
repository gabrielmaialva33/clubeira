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
    plug ClubeiraWeb.Plugs.LoginRateLimit
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
    pipe_through :api

    get "/polos/:polo_slug/catalog", CatalogController, :show
    get "/polos/:polo_slug/checkout-options", CatalogController, :checkout_options
    get "/polos/:polo_slug/places", PlaceController, :index
  end

  scope "/api/v1", ClubeiraWeb do
    pipe_through [:api, :authenticated_api]

    delete "/auth/session", AuthSessionController, :delete
    get "/me/subscriptions", SubscriptionController, :index
    post "/polos/:polo_slug/orders", CheckoutController, :create
    post "/polos/:polo_slug/places/:place_id/reviews", ReviewController, :create
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
