defmodule ClubeiraWeb.Member.SubscriptionController do
  use ClubeiraWeb, :controller

  require Logger

  alias Clubeira.Subscriptions
  alias ClubeiraWeb.ErrorJSON

  def index(conn, params) do
    pagination_params = Map.take(params, ["after", "limit"])

    case Subscriptions.list_for_account(
           conn.assigns.current_account_scope,
           pagination_params
         ) do
      {:ok, page} ->
        render(conn, :index, subscriptions: page.subscriptions, page: page.page)

      {:error, :invalid_pagination} ->
        conn
        |> put_status(:bad_request)
        |> json(ErrorJSON.render("400.json", %{}))

      {:error, reason} ->
        Logger.error("could not list member subscriptions: #{inspect(reason)}")

        conn
        |> put_status(:service_unavailable)
        |> json(ErrorJSON.render("503.json", %{}))
    end
  end
end
