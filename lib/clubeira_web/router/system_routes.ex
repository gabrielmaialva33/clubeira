defmodule ClubeiraWeb.Router.SystemRoutes do
  @moduledoc false

  defmacro system_routes do
    quote do
      scope "/", ClubeiraWeb.System do
        pipe_through :browser

        get "/api/docs", ApiDocsController, :index
      end

      scope "/", ClubeiraWeb.System do
        pipe_through :api

        get "/health", HealthController, :show
        get "/ready", ReadinessController, :show
      end
    end
  end
end
