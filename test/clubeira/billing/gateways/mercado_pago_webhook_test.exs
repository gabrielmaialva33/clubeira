defmodule Clubeira.Billing.MercadoPagoWebhookTest do
  use ExUnit.Case, async: false

  alias Clubeira.Billing.Gateways.MercadoPago
  alias Clubeira.Billing.MerchantAccount

  @account_reference "merchant-webhook-test"
  @webhook_secret "test-webhook-secret-with-at-least-32-bytes"

  setup do
    previous = Application.get_env(:clubeira, MercadoPago)

    Application.put_env(:clubeira, MercadoPago,
      accounts: %{
        @account_reference => %{
          access_token: "test-access-token",
          webhook_secret: @webhook_secret
        }
      }
    )

    on_exit(fn -> restore_configuration(previous) end)

    %{account: %MerchantAccount{provider_account_reference: @account_reference}}
  end

  test "authenticates and normalizes a payment notification without trusting payment data", %{
    account: account
  } do
    provider_reference = "provider-order-123"
    request_id = "provider-event-123"

    assert {:ok,
            %{
              kind: :payment,
              provider_reference: ^provider_reference,
              external_event_id: ^request_id
            }} =
             MercadoPago.verify_webhook(
               account,
               envelope("order", provider_reference, request_id, %{
                 "action" => "order.processed",
                 "type" => "order",
                 "data" => %{"id" => provider_reference}
               })
             )
  end

  test "normalizes recurring invoice and chargeback notification identities", %{account: account} do
    invoice_reference = "provider-invoice-123"
    provider_request_id = "provider-event-invoice"
    invoice_event_id = "subscription_authorized_payment:#{invoice_reference}"

    assert {:ok,
            %{
              kind: :recurring_invoice,
              provider_reference: ^invoice_reference,
              external_event_id: ^invoice_event_id
            }} =
             MercadoPago.verify_webhook(
               account,
               envelope(
                 "subscription_authorized_payment",
                 invoice_reference,
                 provider_request_id,
                 %{
                   "action" => "subscription_authorized_payment.created",
                   "type" => "subscription_authorized_payment",
                   "data" => %{"id" => invoice_reference}
                 }
               )
             )

    chargeback_reference = "123456"
    payment_reference = "provider-payment-123"
    chargeback_event_id = "provider-event-chargeback"

    assert {:ok,
            %{
              kind: :chargeback,
              provider_reference: ^chargeback_reference,
              provider_payment_reference: ^payment_reference,
              external_event_id: ^chargeback_event_id
            }} =
             MercadoPago.verify_webhook(
               account,
               envelope(
                 "topic_chargebacks_wh",
                 chargeback_reference,
                 chargeback_event_id,
                 %{
                   "actions" => ["changed_case_status"],
                   "type" => "topic_chargebacks_wh",
                   "data" => %{
                     "id" => String.to_integer(chargeback_reference),
                     "payment_id" => payment_reference
                   }
                 }
               )
             )
  end

  test "rejects mismatched identities before authentication or provider fetch", %{
    account: account
  } do
    assert {:error, :invalid_webhook} =
             MercadoPago.verify_webhook(
               account,
               envelope("order", "query-reference", "provider-event", %{
                 "action" => "order.processed",
                 "type" => "order",
                 "data" => %{"id" => "body-reference"}
               })
             )
  end

  test "maps an invalid signature to the provider-neutral unauthorized error", %{account: account} do
    envelope =
      "order"
      |> envelope("provider-order-123", "provider-event-123", %{
        "action" => "order.processed",
        "type" => "order",
        "data" => %{"id" => "provider-order-123"}
      })
      |> put_in([:headers, "x-signature"], ["ts=1,v1=#{String.duplicate("0", 64)}"])

    assert {:error, :webhook_unauthorized} = MercadoPago.verify_webhook(account, envelope)
  end

  defp envelope(event_type, provider_reference, request_id, body) do
    %{
      body_params: body,
      headers: %{
        "x-request-id" => [request_id],
        "x-signature" => [webhook_signature(provider_reference, request_id)]
      },
      query_params: %{"data.id" => provider_reference, "type" => event_type},
      raw_body: Jason.encode!(body)
    }
  end

  defp webhook_signature(data_id, request_id) do
    timestamp = System.system_time(:millisecond) |> Integer.to_string()
    manifest = "id:#{data_id};request-id:#{request_id};ts:#{timestamp};"

    digest =
      :crypto.mac(:hmac, :sha256, @webhook_secret, manifest)
      |> Base.encode16(case: :lower)

    "ts=#{timestamp},v1=#{digest}"
  end

  defp restore_configuration(nil), do: Application.delete_env(:clubeira, MercadoPago)

  defp restore_configuration(configuration),
    do: Application.put_env(:clubeira, MercadoPago, configuration)
end
