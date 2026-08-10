defmodule Clubeira.Billing.CheckoutRequestTest do
  use ExUnit.Case, async: true

  alias Clubeira.Billing.CheckoutRequest

  test "accepts only one subscription item and validates the idempotency key" do
    attributes = %{
      product_offering_version_id: Ecto.UUID.generate(),
      offering_price_id: Ecto.UUID.generate(),
      idempotency_key: "checkout.valid-01"
    }

    assert {:ok, request} = CheckoutRequest.new(attributes)
    assert request.quantity == 1

    assert {:error, changeset} = CheckoutRequest.new(Map.put(attributes, :quantity, 2))
    assert errors_on(changeset).quantity == ["must be equal to 1"]

    assert {:error, changeset} =
             CheckoutRequest.new(Map.put(attributes, :idempotency_key, "bad key"))

    assert "has invalid format" in errors_on(changeset).idempotency_key
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        options |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
