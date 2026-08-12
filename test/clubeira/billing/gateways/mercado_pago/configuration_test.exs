defmodule Clubeira.Billing.Gateways.MercadoPago.ConfigurationTest do
  use ExUnit.Case, async: false

  alias Clubeira.Billing.Gateways.MercadoPago
  alias Clubeira.Billing.Gateways.MercadoPago.Configuration

  @access_token "test-access-token"
  @webhook_secret "test-webhook-secret-with-at-least-32-bytes"

  setup do
    previous = Application.get_env(:clubeira, MercadoPago)

    on_exit(fn ->
      if previous do
        Application.put_env(:clubeira, MercadoPago, previous)
      else
        Application.delete_env(:clubeira, MercadoPago)
      end
    end)
  end

  test "parses a bounded account map from deployment JSON" do
    assert %{
             "merchant-demo" => %{
               access_token: @access_token,
               webhook_secret: @webhook_secret
             }
           } =
             Configuration.parse_accounts!(
               Jason.encode!(%{
                 "merchant-demo" => %{
                   "access_token" => @access_token,
                   "webhook_secret" => @webhook_secret
                 }
               })
             )
  end

  test "rejects malformed, empty and unbounded deployment credentials" do
    invalids = [
      nil,
      "not-json",
      "[]",
      "{}",
      Jason.encode!(%{" merchant" => credentials()}),
      Jason.encode!(%{"merchant" => %{credentials() | "access_token" => "short"}}),
      Jason.encode!(%{"merchant" => %{credentials() | "webhook_secret" => "short"}}),
      Jason.encode!(%{String.duplicate("m", 256) => credentials()}),
      Jason.encode!(%{"merchant" => %{"access_token" => @access_token}})
    ]

    for invalid <- invalids do
      assert_raise ArgumentError, ~r/MERCADO_PAGO_ACCOUNTS_JSON/, fn ->
        Configuration.parse_accounts!(invalid)
      end
    end
  end

  test "reads atom-keyed and JSON-shaped runtime account credentials" do
    Application.put_env(:clubeira, MercadoPago,
      accounts: %{
        "atom-account" => %{access_token: @access_token, webhook_secret: @webhook_secret},
        "string-account" => %{
          "access_token" => @access_token,
          "webhook_secret" => @webhook_secret
        }
      },
      subscription_back_url: "https://clubeira.example/app/subscriptions",
      req_options: [retry: false]
    )

    for account <- ["atom-account", "string-account"] do
      assert Configuration.access_token(account) == {:ok, @access_token}
      assert Configuration.webhook_secret(account) == {:ok, @webhook_secret}
    end

    assert Configuration.subscription_back_url() ==
             {:ok, "https://clubeira.example/app/subscriptions"}

    assert Configuration.request_options() == [retry: false]
  end

  test "fails closed when runtime gateway settings are absent or weak" do
    Application.put_env(:clubeira, MercadoPago,
      accounts: %{
        "weak" => %{access_token: "short", webhook_secret: "short"}
      }
    )

    assert Configuration.access_token("missing") == {:error, :payment_gateway_not_configured}
    assert Configuration.webhook_secret("missing") == {:error, :payment_gateway_not_configured}
    assert Configuration.access_token("weak") == {:error, :payment_gateway_not_configured}
    assert Configuration.webhook_secret("weak") == {:error, :payment_gateway_not_configured}
    assert Configuration.subscription_back_url() == {:error, :payment_gateway_not_configured}
    assert Configuration.request_options() == []
  end

  defp credentials do
    %{"access_token" => @access_token, "webhook_secret" => @webhook_secret}
  end
end
