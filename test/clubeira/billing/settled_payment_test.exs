defmodule Clubeira.Billing.SettledPaymentTest do
  use ExUnit.Case, async: true

  alias Clubeira.Billing.SettledPayment

  test "validates the normalized capture instead of accepting a provider payload directly" do
    attributes = %{
      order_id: Ecto.UUID.generate(),
      payment_provider_id: Ecto.UUID.generate(),
      merchant_account_id: Ecto.UUID.generate(),
      external_event_id: "evt_123",
      provider_reference: "pay_123",
      amount: "29.90",
      currency: "BRL",
      occurred_at: DateTime.utc_now(:microsecond),
      payload: %{"safe" => true}
    }

    assert {:ok, request} = SettledPayment.new(attributes)
    assert Decimal.equal?(request.amount, Decimal.new("29.90"))

    assert {:error, changeset} = SettledPayment.new(Map.put(attributes, :currency, "brl"))
    assert errors_on(changeset).currency == ["has invalid format"]

    assert {:error, changeset} = SettledPayment.new(Map.put(attributes, :amount, "-0.01"))
    assert errors_on(changeset).amount == ["must be greater than or equal to 0"]
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        options |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
