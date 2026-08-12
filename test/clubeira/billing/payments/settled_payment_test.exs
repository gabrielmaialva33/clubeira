defmodule Clubeira.Billing.SettledPaymentTest do
  use ExUnit.Case, async: true

  alias Clubeira.Billing.SettledPayment

  test "validates the normalized capture instead of accepting a provider payload directly" do
    attributes = valid_attributes()

    assert {:ok, request} = SettledPayment.new(attributes)
    assert Decimal.equal?(request.amount, Decimal.new("29.90"))

    assert {:error, changeset} = SettledPayment.new(Map.put(attributes, :currency, "brl"))
    assert errors_on(changeset).currency == ["has invalid format"]

    assert {:error, changeset} = SettledPayment.new(Map.put(attributes, :amount, "-0.01"))
    assert errors_on(changeset).amount == ["must be greater than or equal to 0"]
  end

  test "returns a changeset for malformed boundary input" do
    assert {:error, changeset} = SettledPayment.new(:invalid)
    assert errors_on(changeset).base == ["must be a map"]
  end

  test "requires provider identity and bounds provider references" do
    for field <- Map.keys(Map.delete(valid_attributes(), :payload)) do
      assert {:error, changeset} = SettledPayment.new(Map.delete(valid_attributes(), field))
      assert Map.has_key?(errors_on(changeset), field)
    end

    for field <- [:external_event_id, :provider_reference] do
      assert {:error, changeset} =
               SettledPayment.new(Map.put(valid_attributes(), field, String.duplicate("x", 256)))

      assert Map.has_key?(errors_on(changeset), field)
    end

    assert {:error, changeset} =
             SettledPayment.new(
               Map.put(valid_attributes(), :provider_intent_reference, String.duplicate("x", 256))
             )

    assert Map.has_key?(errors_on(changeset), :provider_intent_reference)
  end

  test "rejects non-JSON and oversized evidence payloads" do
    assert {:error, invalid_json} =
             SettledPayment.new(%{valid_attributes() | payload: %{pid: self()}})

    assert errors_on(invalid_json).payload == ["must be valid JSON data"]

    assert {:error, too_large} =
             SettledPayment.new(%{
               valid_attributes()
               | payload: %{"blob" => String.duplicate("x", 65_536)}
             })

    assert errors_on(too_large).payload == ["is too large"]
  end

  defp valid_attributes do
    %{
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
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        options |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
