defmodule Clubeira.Billing.GatewaysTest do
  use ExUnit.Case, async: false

  alias Clubeira.Billing.Gateways
  alias Clubeira.Billing.Gateways.MercadoPago

  setup do
    previous = Application.get_env(:clubeira, Gateways)

    Application.put_env(:clubeira, Gateways,
      adapters: %{"test_psp" => MercadoPago},
      payment_providers: %{"pix" => "test_psp"},
      subscription_provider: "test_psp"
    )

    on_exit(fn -> restore_configuration(previous) end)
  end

  test "resolves adapters and consumer routes without creating atoms from provider codes" do
    assert {:ok, MercadoPago} = Gateways.adapter_for("test_psp")
    assert {:ok, "test_psp"} = Gateways.provider_for_payment("pix")
    assert {:ok, "test_psp"} = Gateways.provider_for_subscription()

    assert {:error, :payment_gateway_unsupported} = Gateways.adapter_for("unknown")
    assert {:error, :payment_gateway_unsupported} = Gateways.provider_for_payment("card")
  end

  test "fails closed when a configured route has no registered adapter" do
    Application.put_env(:clubeira, Gateways,
      adapters: %{"test_psp" => MercadoPago},
      payment_providers: %{"pix" => "missing"},
      subscription_provider: "missing"
    )

    assert {:error, :payment_gateway_unsupported} = Gateways.provider_for_payment("pix")
    assert {:error, :payment_gateway_unsupported} = Gateways.provider_for_subscription()
  end

  test "rejects a registered module that does not implement the adapter contract" do
    Application.put_env(:clubeira, Gateways,
      adapters: %{"invalid" => String},
      payment_providers: %{"pix" => "invalid"},
      subscription_provider: "invalid"
    )

    assert {:error, :payment_gateway_unsupported} = Gateways.adapter_for("invalid")
    assert {:error, :payment_gateway_unsupported} = Gateways.provider_for_payment("pix")
    assert {:error, :payment_gateway_unsupported} = Gateways.provider_for_subscription()
  end

  defp restore_configuration(nil), do: Application.delete_env(:clubeira, Gateways)

  defp restore_configuration(configuration),
    do: Application.put_env(:clubeira, Gateways, configuration)
end
