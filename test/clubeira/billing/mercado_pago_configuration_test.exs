defmodule Clubeira.Billing.MercadoPagoConfigurationTest do
  use ExUnit.Case, async: true

  alias Clubeira.Billing.Gateways.MercadoPago.Configuration

  test "parses multiple account credentials without creating dynamic atoms" do
    assert Configuration.parse_accounts!(
             Jason.encode!(%{
               "merchant-sobral" => %{
                 "access_token" => "test-access-token-long-enough",
                 "webhook_secret" => String.duplicate("a", 32)
               },
               "merchant-londrina" => %{
                 "access_token" => "another-access-token-long-enough",
                 "webhook_secret" => String.duplicate("b", 32)
               }
             })
           ) == %{
             "merchant-sobral" => %{
               access_token: "test-access-token-long-enough",
               webhook_secret: String.duplicate("a", 32)
             },
             "merchant-londrina" => %{
               access_token: "another-access-token-long-enough",
               webhook_secret: String.duplicate("b", 32)
             }
           }
  end

  test "fails closed without echoing malformed credentials" do
    secret = "short-and-sensitive"
    configuration = Jason.encode!(%{"merchant-sobral" => %{"access_token" => secret}})

    error =
      assert_raise ArgumentError, fn ->
        Configuration.parse_accounts!(configuration)
      end

    assert error.message =~ "MERCADO_PAGO_ACCOUNTS_JSON"
    refute error.message =~ secret
  end
end
