defmodule ClubeiraWeb.BackofficePaymentController do
  use ClubeiraWeb, :controller

  require Logger

  alias Clubeira.Billing
  alias Clubeira.Polos
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  @query_fields ~w(after limit order_number status)

  def index(conn, %{"polo_slug" => polo_slug} = params) do
    with {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, result} <-
           Billing.list_backoffice_payments(
             scope(conn, route.polo_id),
             Map.take(params, @query_fields)
           ) do
      render(conn, :index, payments: result.payments, page: result.page)
    else
      {:error, :polo_not_found} ->
        render_error(conn, :not_found)

      {:error, :billing_admin_required} ->
        render_error(conn, :forbidden)

      {:error, :invalid_pagination} ->
        render_error(conn, :bad_request)

      {:error, reason} when reason in [:invalid_order_number, :invalid_payment_status] ->
        render_error(conn, :unprocessable_entity)

      {:error, reason} ->
        Logger.error("could not list backoffice payments: #{inspect(reason)}")
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
