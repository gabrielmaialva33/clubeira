defmodule ClubeiraWeb.PaymentWebhookController do
  use ClubeiraWeb, :controller

  alias Clubeira.Billing
  alias ClubeiraWeb.ErrorJSON
  alias Plug.Conn.Status

  @bad_gateway_errors ~w(
    payment_gateway_invalid_response
    payment_gateway_rejected
  )a
  @service_errors ~w(
    payment_gateway_not_configured
    payment_gateway_unavailable
  )a

  def mercado_pago(conn, %{"merchant_account_id" => merchant_account_id} = params) do
    attributes = %{
      merchant_account_id: merchant_account_id,
      internal_request_id: conn.assigns.request_id,
      data_id: params["data.id"],
      body_data_id: get_in(params, ["data", "id"]),
      event_type: params["type"],
      event_action: params["action"],
      provider_request_id: single_header(conn, "x-request-id"),
      signature: single_header(conn, "x-signature")
    }

    case Billing.handle_payment_webhook("mercado_pago", attributes) do
      {:ok, _outcome} ->
        send_resp(conn, :ok, "")

      {:error, :invalid_webhook} ->
        reject_webhook(conn, merchant_account_id, :invalid_webhook, :bad_request)

      {:error, :webhook_unauthorized} ->
        reject_webhook(conn, merchant_account_id, :webhook_unauthorized, :unauthorized)

      {:error, reason} when reason in @service_errors ->
        render_error(conn, :service_unavailable)

      {:error, reason} when reason in @bad_gateway_errors ->
        render_error(conn, :bad_gateway)

      {:error, _settlement_reason} ->
        render_error(conn, :unprocessable_entity)
    end
  end

  defp single_header(conn, name) do
    case get_req_header(conn, name) do
      [value] -> value
      _missing_or_ambiguous -> nil
    end
  end

  defp reject_webhook(conn, merchant_account_id, reason, status) do
    :telemetry.execute(
      [:clubeira, :billing, :webhook_rejected],
      %{count: 1},
      %{
        merchant_account_id: merchant_account_id,
        provider: "mercado_pago",
        reason: reason
      }
    )

    render_error(conn, status)
  end

  defp render_error(conn, status) do
    conn
    |> put_status(status)
    |> json(ErrorJSON.render("#{Status.code(status)}.json", %{}))
  end
end
