defmodule ClubeiraWeb.Router do
  use ClubeiraWeb, :router

  import ClubeiraWeb.Router.AuthRoutes
  import ClubeiraWeb.Router.BackofficeRoutes
  import ClubeiraWeb.Router.MemberRoutes
  import ClubeiraWeb.Router.PartnerRoutes
  import ClubeiraWeb.Router.PlatformRoutes
  import ClubeiraWeb.Router.PublicRoutes
  import ClubeiraWeb.Router.SystemRoutes

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
    plug ClubeiraWeb.Plugs.ApiLocale
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

  system_routes()
  auth_routes()
  public_routes()
  member_routes()
  platform_routes()
  backoffice_routes()
  partner_routes()

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
