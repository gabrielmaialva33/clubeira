defmodule ClubeiraWeb.Router.MemberRoutes do
  @moduledoc false

  defmacro member_routes do
    quote do
      scope "/api/v1", ClubeiraWeb.Member do
        pipe_through [:api, :authenticated_api]

        get "/me", AccountController, :show
        get "/me/access", AccessBootstrapController, :show
        get "/me/profile", ProfileController, :show
        put "/me/profile", ProfileController, :update
        get "/me/privacy/consents", PrivacyController, :index_consents
        put "/me/privacy/consents/:purpose_code", PrivacyController, :update_consent
        get "/me/privacy/requests", PrivacyController, :index_requests
        post "/me/privacy/requests", PrivacyController, :create_request
        get "/me/subscriptions", SubscriptionController, :index
        get "/polos/:polo_slug/me/billing", BillingAgreementController, :index
        post "/polos/:polo_slug/orders", CheckoutController, :create

        post "/polos/:polo_slug/orders/:order_id/payment-intents",
             PaymentIntentController,
             :create

        post "/polos/:polo_slug/orders/:order_id/billing-agreements",
             BillingAgreementController,
             :create

        post "/polos/:polo_slug/me/redemption-devices", RedemptionDeviceController, :create
        get "/me/devices/:device_id/key", DeviceKeyController, :show
        put "/me/devices/:device_id/key", DeviceKeyController, :update
        post "/polos/:polo_slug/me/redemption-grants", RedemptionGrantController, :create
        get "/polos/:polo_slug/me/orders", OrderController, :index
        get "/polos/:polo_slug/me/redemptions", RedemptionController, :index
        get "/polos/:polo_slug/me/vouchers", WalletController, :index
      end

      scope "/api/v1", ClubeiraWeb.Reviews do
        pipe_through [:api, :authenticated_api]

        post "/polos/:polo_slug/places/:place_id/reviews", ReviewController, :create

        post "/polos/:polo_slug/places/:place_id/reviews/:review_id/media",
             ReviewMediaController,
             :create

        post "/polos/:polo_slug/places/:place_id/reviews/:review_id/reports",
             ReviewReportController,
             :create
      end
    end
  end
end
