defmodule Clubeira.Billing.ProviderSelectionTest do
  use Clubeira.DataCase, async: false

  import Plug.Conn

  alias Clubeira.Billing
  alias Clubeira.Billing.Gateways
  alias Clubeira.Billing.Gateways.MercadoPago
  alias Clubeira.BillingFixtures

  test "starts a member payment through the provider selected in gateway configuration" do
    fixture = BillingFixtures.create!()

    fixture.provider
    |> Ecto.Changeset.change(code: "test_psp")
    |> Repo.update!()

    configure_gateway!(fixture)

    assert {:ok, order} =
             Billing.place_order(fixture.member_scope, BillingFixtures.checkout_request(fixture))

    Req.Test.expect(MercadoPago, fn request ->
      request
      |> put_status(:created)
      |> Req.Test.json(%{
        id: "test-order-reference",
        status: "action_required",
        transactions: %{
          payments: [
            %{
              id: "test-payment-reference",
              amount: Decimal.to_string(order.total_amount),
              payment_method: %{
                id: "pix",
                type: "bank_transfer",
                ticket_url: "https://www.mercadopago.com.br/payments/test/ticket",
                qr_code: "test-copy-paste-code"
              }
            }
          ]
        }
      })
    end)

    assert {:ok, %{provider: "test_psp", payment_intent: intent}} =
             Billing.start_payment(fixture.member_scope, %{
               order_id: order.id,
               payment_method: "pix",
               idempotency_key: "test-provider-selection"
             })

    assert intent.provider_reference == "test-order-reference"
    assert intent.status == "requires_action"
  end

  defp configure_gateway!(fixture) do
    previous_gateways = Application.get_env(:clubeira, Gateways)
    previous_mercado_pago = Application.get_env(:clubeira, MercadoPago)

    Application.put_env(:clubeira, Gateways,
      adapters: %{"test_psp" => MercadoPago},
      payment_providers: %{"pix" => "test_psp"},
      subscription_provider: "test_psp"
    )

    Application.put_env(:clubeira, MercadoPago,
      accounts: %{
        fixture.merchant_account.provider_account_reference => %{
          access_token: "test-access-token",
          webhook_secret: String.duplicate("s", 32)
        }
      },
      req_options: [plug: {Req.Test, MercadoPago}]
    )

    on_exit(fn ->
      restore_configuration(Gateways, previous_gateways)
      restore_configuration(MercadoPago, previous_mercado_pago)
    end)
  end

  defp restore_configuration(module, nil), do: Application.delete_env(:clubeira, module)
  defp restore_configuration(module, value), do: Application.put_env(:clubeira, module, value)
end
