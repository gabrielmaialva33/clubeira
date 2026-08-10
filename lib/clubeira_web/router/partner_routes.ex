defmodule ClubeiraWeb.Router.PartnerRoutes do
  @moduledoc false

  defmacro partner_routes do
    quote do
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
