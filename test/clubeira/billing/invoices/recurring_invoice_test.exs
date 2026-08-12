defmodule Clubeira.Billing.RecurringInvoiceTest do
  use ExUnit.Case, async: true

  alias Clubeira.Billing.RecurringInvoice

  test "normalizes a complete recurring capture" do
    attributes = valid_attributes()

    assert {:ok, invoice} = RecurringInvoice.new(attributes)
    assert invoice.status == "captured"
    assert invoice.currency == "BRL"
    assert Decimal.equal?(invoice.amount, Decimal.new("29.90"))
    assert invoice.payload == %{"source" => "provider"}
  end

  test "returns a changeset for non-map input" do
    assert {:error, changeset} = RecurringInvoice.new(:invalid)
    assert %{base: ["must be a map"]} = errors_on(changeset)
  end

  test "validates identifiers, amount, currency and terminal status" do
    invalids = [
      {:billing_agreement_reference, ""},
      {:provider_invoice_reference, String.duplicate("x", 256)},
      {:provider_payment_reference, ""},
      {:external_event_id, ""},
      {:amount, "0"},
      {:currency, "brl"},
      {:status, "pending"}
    ]

    for {field, value} <- invalids do
      assert {:error, changeset} = RecurringInvoice.new(Map.put(valid_attributes(), field, value))
      assert Map.has_key?(errors_on(changeset), field)
    end
  end

  test "requires every provider proof field" do
    for field <- Map.keys(Map.delete(valid_attributes(), :payload)) do
      assert {:error, changeset} = RecurringInvoice.new(Map.delete(valid_attributes(), field))
      assert Map.has_key?(errors_on(changeset), field)
    end
  end

  test "rejects payloads that are not JSON or exceed the evidence limit" do
    assert {:error, invalid_json} =
             RecurringInvoice.new(%{valid_attributes() | payload: %{pid: self()}})

    assert %{payload: ["must be valid JSON data"]} = errors_on(invalid_json)

    assert {:error, too_large} =
             RecurringInvoice.new(%{
               valid_attributes()
               | payload: %{"blob" => String.duplicate("x", 65_536)}
             })

    assert %{payload: ["is too large"]} = errors_on(too_large)
  end

  defp valid_attributes do
    %{
      billing_agreement_reference: "agreement-1",
      provider_invoice_reference: "invoice-1",
      provider_payment_reference: "payment-1",
      external_event_id: "event-1",
      polo_id: uuid7(),
      order_id: uuid7(),
      amount: "29.90",
      currency: "BRL",
      occurred_at: DateTime.utc_now(:microsecond),
      status: "captured",
      payload: %{"source" => "provider"}
    }
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _options} -> message end)
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
