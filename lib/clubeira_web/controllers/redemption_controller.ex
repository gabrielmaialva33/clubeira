defmodule ClubeiraWeb.RedemptionController do
  use ClubeiraWeb, :controller

  require Logger

  alias Clubeira.Polos
  alias Clubeira.Redemptions
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  def index(conn, %{"polo_slug" => polo_slug} = params) do
    with {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, result} <-
           Redemptions.list_for_member(
             redemption_scope(conn, route.polo_id),
             pagination_params(params)
           ) do
      render(conn, :index, redemptions: result.redemptions, page: result.page)
    else
      {:error, :polo_not_found} ->
        render_error(conn, :not_found)

      {:error, :invalid_pagination} ->
        render_error(conn, :bad_request)

      {:error, reason} ->
        Logger.error("could not list member redemptions: #{inspect(reason)}")
        render_error(conn, :service_unavailable)
    end
  end

  defp redemption_scope(conn, polo_id) do
    account_scope = conn.assigns.current_account_scope

    Scope.new!(polo_id,
      actor_user_id: account_scope.user.id,
      request_id: account_scope.request_id
    )
  end

  defp pagination_params(params), do: Map.take(params, ["after", "limit"])

  defp render_error(conn, status) do
    conn
    |> put_status(status)
    |> json(ErrorJSON.render("#{Status.code(status)}.json", %{}))
  end
end
