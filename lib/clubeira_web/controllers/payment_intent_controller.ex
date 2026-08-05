defmodule ClubeiraWeb.PaymentIntentController do
  use ClubeiraWeb, :controller

  alias Clubeira.Billing
  alias Clubeira.Polos
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  @payment_fields ~w(payment_method)
  @bad_gateway_errors ~w(
    payment_gateway_invalid_response
    payment_gateway_rejected
  )a
  @service_errors ~w(
    payment_gateway_not_configured
    payment_gateway_unavailable
  )a

  def create(conn, %{"polo_slug" => polo_slug, "order_id" => order_id} = params) do
    with {:ok, idempotency_key} <- fetch_idempotency_key(conn),
         {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, payment} <-
           Billing.start_payment(
             payment_scope(conn, route.polo_id),
             payment_attributes(params, order_id, idempotency_key)
           ) do
      conn
      |> put_status(:created)
      |> render(:create, payment: payment)
    else
      {:error, reason} when reason in [:polo_not_found, :order_not_found] ->
        render_error(conn, :not_found)

      {:error, reason}
      when reason in [
             :idempotency_conflict,
             :payment_already_started,
             :payment_intent_unavailable
           ] ->
        render_error(conn, :conflict)

      {:error, reason} when reason in @service_errors ->
        render_error(conn, :service_unavailable)

      {:error, reason} when reason in @bad_gateway_errors ->
        render_error(conn, :bad_gateway)

      {:error, reason}
      when reason in [
             :actor_required,
             :invalid_idempotency_key,
             :order_not_payable,
             :payment_gateway_unsupported
           ] ->
        render_error(conn, :unprocessable_entity)

      {:error, %Ecto.Changeset{}} ->
        render_error(conn, :unprocessable_entity)
    end
  end

  defp fetch_idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [idempotency_key] -> {:ok, idempotency_key}
      _missing_or_ambiguous -> {:error, :invalid_idempotency_key}
    end
  end

  defp payment_scope(conn, polo_id) do
    account_scope = conn.assigns.current_account_scope

    Scope.new!(polo_id,
      actor_user_id: account_scope.user.id,
      request_id: account_scope.request_id
    )
  end

  defp payment_attributes(params, order_id, idempotency_key) do
    params
    |> Map.take(@payment_fields)
    |> Map.put("order_id", order_id)
    |> Map.put("idempotency_key", idempotency_key)
  end

  defp render_error(conn, status) do
    conn
    |> put_status(status)
    |> json(ErrorJSON.render("#{Status.code(status)}.json", %{}))
  end
end
