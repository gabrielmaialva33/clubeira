defmodule Clubeira.Billing.Gateways.MercadoPago.ValueTest do
  use ExUnit.Case, async: true

  alias Clubeira.Billing.Gateways.MercadoPago.Value

  test "validates currencies and bounded provider strings" do
    assert Value.currency?("BRL")
    refute Value.currency?("brl")
    refute Value.currency?("REAL")
    refute Value.currency?(nil)

    assert Value.pix_code?("000201")
    refute Value.pix_code?("")
    refute Value.pix_code?(String.duplicate("x", 4_097))
    refute Value.pix_code?(123)

    assert Value.reference?("provider-reference")
    refute Value.reference?("")
    refute Value.reference?(String.duplicate("x", 256))
    refute Value.reference?(123)
  end

  test "parses provider datetimes without accepting other input shapes" do
    assert {:ok, ~U[2026-08-12 18:00:00Z]} = Value.datetime("2026-08-12T18:00:00Z")
    assert :error = Value.datetime("not-a-datetime")
    assert :error = Value.datetime(nil)
  end

  test "normalizes all supported decimal representations" do
    decimal = Decimal.new("29.90")

    assert {:ok, ^decimal} = Value.decimal(decimal)
    assert {:ok, value} = Value.decimal(29)
    assert Decimal.equal?(value, Decimal.new(29))
    assert {:ok, value} = Value.decimal(29.9)
    assert Decimal.equal?(value, Decimal.new("29.9"))
    assert {:ok, value} = Value.decimal("29.90")
    assert Decimal.equal?(value, decimal)
    assert :error = Value.decimal("29.90 BRL")
    assert :error = Value.decimal(nil)
    assert Value.decimal_string(decimal) == "29.9"
  end

  test "parses tenant and platform external references exactly" do
    polo_id = uuid7()
    resource_id = uuid7()

    assert {:ok, ^polo_id, ^resource_id} =
             Value.external_reference("#{polo_id}_#{resource_id}")

    assert {:ok, ^polo_id, ^resource_id} =
             Value.platform_external_reference("#{polo_id}:#{resource_id}")

    for invalid <- ["", polo_id, "invalid_#{resource_id}", 123, nil] do
      assert :error = Value.external_reference(invalid)
    end

    for invalid <- ["", polo_id, "invalid:#{resource_id}", 123, nil] do
      assert :error = Value.platform_external_reference(invalid)
    end
  end

  test "accepts only bounded Mercado Pago HTTPS redirect hosts" do
    assert Value.redirect_url?("https://mercadopago.com.br/checkout")
    assert Value.redirect_url?("https://www.mercadopago.com.br/checkout")

    refute Value.redirect_url?("http://mercadopago.com.br/checkout")
    refute Value.redirect_url?("https://mercadopago.com.br.evil.test/checkout")
    refute Value.redirect_url?("https://example.com/checkout")
    refute Value.redirect_url?("https:///checkout")
    refute Value.redirect_url?(String.duplicate("x", 2_049))
    refute Value.redirect_url?(nil)
  end

  test "normalizes reference identifiers without inventing values" do
    assert Value.reference_string("abc") == "abc"
    assert Value.reference_string(0) == "0"
    assert Value.reference_string(42) == "42"
    assert Value.reference_string(-1) == nil
    assert Value.reference_string(nil) == nil
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
