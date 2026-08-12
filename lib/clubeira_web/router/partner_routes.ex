defmodule ClubeiraWeb.Router.PartnerRoutes do
  @moduledoc false

  defmacro partner_routes do
    quote do
      scope "/partner", ClubeiraWeb, as: :partner_browser do
        pipe_through [:browser, :private_browser]

        get "/login", Auth.BrowserSessionController, :partner_new
        delete "/logout", Auth.BrowserSessionController, :partner_delete
      end

      scope "/partner", ClubeiraWeb, as: :partner_browser do
        pipe_through [:browser, :private_browser, :browser_login]

        post "/login", Auth.BrowserSessionController, :partner_create
      end

      scope "/partner", ClubeiraWeb.Partner, as: :partner_browser do
        pipe_through [:browser, :private_browser]

        live_session :partner,
          on_mount: [{ClubeiraWeb.PartnerAuth, :ensure_authenticated}] do
          live "/", PlacesLive, :index
          live "/places/:polo_slug/:polo_place_id", PlaceLive, :show
          live "/reviews", ReviewsLive, :index
        end
      end

      scope "/api/v1/polos/:polo_slug/partner", ClubeiraWeb.Partner, as: :partner do
        pipe_through [:api, :authenticated_api]

        get "/places", PlaceController, :index
        put "/reviews/:review_id/response", ReviewResponseController, :update
      end

      scope "/api/v1/polos/:polo_slug/partner", ClubeiraWeb.Backoffice do
        pipe_through [:api, :authenticated_api]

        put "/places/:place_id/profile",
            PlaceProfileController,
            :update,
            as: :backoffice_place_profile
      end
    end
  end
end
