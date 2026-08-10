defmodule ClubeiraWeb.Backoffice.SubscriptionController do
  use ClubeiraWeb, :controller

  require Logger

  alias Clubeira.Polos
  alias Clubeira.Subscriptions
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  @query_fields ~w(after limit order_number product_offering_version_id purchaser_user_id status)

  def index(conn, %{"polo_slug" => polo_slug} = params) do
    with {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, result} <-
           Subscriptions.list_backoffice_subscriptions(
             scope(conn, route.polo_id),
             Map.take(params, @query_fields)
           ) do
      render(conn, :index, subscriptions: result.subscriptions, page: result.page)
    else
      {:error, :polo_not_found} ->
        render_error(conn, :not_found)

      {:error, :billing_admin_required} ->
        render_error(conn, :forbidden)

      {:error, :invalid_pagination} ->
        render_error(conn, :bad_request)

      {:error, :invalid_subscription_status} ->
        render_error(conn, :unprocessable_entity)

      {:error, :invalid_order_number} ->
        render_error(conn, :unprocessable_entity)

      {:error, :invalid_subscription_filter} ->
        render_error(conn, :unprocessable_entity)

      {:error, reason} ->
        Logger.error("could not list backoffice subscriptions: #{inspect(reason)}")
        render_error(conn, :service_unavailable)
    end
  end

  defp scope(conn, polo_id) do
    account_scope = conn.assigns.current_account_scope

    Scope.new!(polo_id,
      actor_user_id: account_scope.user.id,
      request_id: account_scope.request_id
    )
  end

  defp render_error(conn, status) do
    conn
    |> put_status(status)
    |> json(ErrorJSON.render("#{Status.code(status)}.json", %{}))
  end
end
