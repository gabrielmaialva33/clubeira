defmodule ClubeiraWeb.Router.PublicRoutes do
  @moduledoc false

  defmacro public_routes do
    quote do
      scope "/", ClubeiraWeb.Public, as: :public_browser do
        pipe_through :browser

        live_session :public_discovery,
          on_mount: [{ClubeiraWeb.PublicLocale, :set_locale}] do
          live "/termos", LegalLive, :index
          live "/explorar", PolosLive, :index
          live "/explorar/:polo_slug/lugares/:place_slug", PlaceLive, :show
          live "/explorar/:polo_slug", PoloLive, :show
        end
      end

      scope "/api/v1", ClubeiraWeb.Public do
        pipe_through :api

        get "/polos", PoloController, :index
        get "/polos/:polo_slug/catalog", CatalogController, :show
        get "/polos/:polo_slug/checkout-options", CatalogController, :checkout_options
        get "/polos/:polo_slug/places", PlaceController, :index
        get "/legal/registration", LegalController, :registration
      end

      scope "/api/v1", ClubeiraWeb.Reviews do
        pipe_through :api

        get "/polos/:polo_slug/places/:place_id/reviews", ReviewController, :index
        get "/polos/:polo_slug/review-media/:media_id", ReviewMediaController, :show
      end

      scope "/api/v1", ClubeiraWeb.Validation do
        pipe_through :api

        post "/polos/:polo_slug/redemptions", RedemptionConfirmationController, :create
      end

      scope "/api/v1", ClubeiraWeb.Webhooks do
        pipe_through :api

        post "/webhooks/mercado-pago/:merchant_account_id",
             PaymentWebhookController,
             :mercado_pago

        post "/webhooks/:provider_code/:merchant_account_id",
             PaymentWebhookController,
             :provider
      end
    end
  end
end
