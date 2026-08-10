defmodule ClubeiraWeb.Backoffice.PaymentRefundController do
  use ClubeiraWeb, :controller

  alias Clubeira.Billing
  alias Clubeira.Polos
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  @conflict_errors ~w(
    idempotency_conflict
    payment_already_refunded
    payment_not_refundable
    refund_in_progress
    refund_unavailable
  )a

  @service_errors ~w(
    payment_gateway_not_configured
    payment_gateway_unavailable
  )a

  def create(conn, %{"polo_slug" => polo_slug, "payment_id" => payment_id} = params) do
    with {:ok, idempotency_key} <- fetch_idempotency_key(conn),
         {:ok, route} <- Polos.resolve_route(polo_slug),
         {:ok, refund} <-
           Billing.refund_payment(
             scope(conn, route.polo_id),
             payment_id,
             refund_attributes(params, idempotency_key)
           ) do
      conn
      |> put_status(:created)
      |> render(:create, refund: refund)
    else
      {:error, reason} when reason in [:polo_not_found, :payment_not_found] ->
        render_error(conn, :not_found)

      {:error, :billing_admin_required} ->
        render_error(conn, :forbidden)

      {:error, reason} when reason in @conflict_errors ->
        render_error(conn, :conflict, Atom.to_string(reason))

      {:error, :invalid_idempotency_key} ->
        render_error(conn, :bad_request, "invalid_idempotency_key")

      {:error, :payment_gateway_invalid_response} ->
        render_error(conn, :bad_gateway)

      {:error, reason} when reason in @service_errors ->
        render_error(conn, :service_unavailable)

      {:error, :payment_gateway_rejected} ->
        render_error(conn, :unprocessable_entity, "payment_gateway_rejected")

      {:error, %Ecto.Changeset{}} ->
        render_error(conn, :unprocessable_entity)

      {:error, _reason} ->
        render_error(conn, :unprocessable_entity)
    end
  end

  defp scope(conn, polo_id) do
    account_scope = conn.assigns.current_account_scope

    Scope.new!(polo_id,
      actor_user_id: account_scope.user.id,
      request_id: account_scope.request_id
    )
  end

  defp refund_attributes(params, idempotency_key) do
    params
    |> Map.take(["reason"])
    |> Map.put("idempotency_key", idempotency_key)
  end

  defp fetch_idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [idempotency_key] -> {:ok, idempotency_key}
      _missing_or_ambiguous -> {:error, :invalid_idempotency_key}
    end
  end

  defp render_error(conn, status) do
    conn
    |> put_status(status)
    |> json(ErrorJSON.render("#{Status.code(status)}.json", %{}))
  end

  defp render_error(conn, status, code) do
    conn
    |> put_status(status)
    |> json(ErrorJSON.render("#{Status.code(status)}.json", %{code: code}))
  end
end
