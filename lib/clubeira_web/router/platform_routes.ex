defmodule ClubeiraWeb.Router.PlatformRoutes do
  @moduledoc false

  defmacro platform_routes do
    quote do
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
