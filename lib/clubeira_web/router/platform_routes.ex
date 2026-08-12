defmodule ClubeiraWeb.Router.PlatformRoutes do
  @moduledoc false

  defmacro platform_routes do
    quote do
      scope "/platform", ClubeiraWeb, as: :platform_browser do
        pipe_through [:browser, :private_browser]

        get "/login", Auth.BrowserSessionController, :platform_new
        delete "/logout", Auth.BrowserSessionController, :platform_delete
      end

      scope "/platform", ClubeiraWeb, as: :platform_browser do
        pipe_through [:browser, :private_browser, :browser_login]

        post "/login", Auth.BrowserSessionController, :platform_create
      end

      scope "/platform", ClubeiraWeb.Platform, as: :platform_browser do
        pipe_through [:browser, :private_browser]

        live_session :platform,
          on_mount: [{ClubeiraWeb.PlatformAuth, :ensure_authenticated}] do
          live "/", DashboardLive, :index
          live "/billing/plans", BillingPlansLive, :index
          live "/privacy/requests", PrivacyRequestsLive, :index
          live "/privacy/requests/:request_id", PrivacyRequestLive, :show
          live "/privacy/purposes", PrivacyPurposesLive, :index
        end
      end

      scope "/api/v1/platform", ClubeiraWeb.Platform, as: :platform do
        pipe_through [:api, :authenticated_api]

        get "/privacy/processing-purposes", PrivacyController, :index_processing_purposes

        put "/privacy/processing-purposes/:purpose_code",
            PrivacyController,
            :put_processing_purpose

        get "/privacy/requests", PrivacyController, :index_requests
        post "/privacy/requests/:request_id/transitions", PrivacyController, :transition_request
        get "/billing/plans", BillingPlanController, :index
        put "/billing/plans/:plan_code/versions/:version", BillingPlanController, :put_version
      end

      scope "/api/v1/polos/:polo_slug/backoffice", ClubeiraWeb.Platform, as: :platform do
        pipe_through [:api, :authenticated_api]

        post "/platform-subscription", SubscriptionController, :create
        get "/platform-billing", BillingController, :show
      end
    end
  end
end
