defmodule Clubeira.Redemptions.ConfirmedRequestTest do
  use ExUnit.Case, async: true

  alias Clubeira.Redemptions.ConfirmedRequest

  test "accepts a bounded JSON-safe command" do
    assert {:ok, request} = ConfirmedRequest.new(valid_attributes())
    assert byte_size(ConfirmedRequest.nonce_hash(request)) == 32
    assert request.request_context == %{"channel" => "mobile"}
  end

  test "rejects malformed identifiers and weak replay keys" do
    attributes = %{
      valid_attributes()
      | entitlement_allocation_id: "not-a-uuid",
        idempotency_key: "short",
        request_nonce: "tiny"
    }

    assert {:error, changeset} = ConfirmedRequest.new(attributes)

    assert "is invalid" in errors_on(changeset).entitlement_allocation_id
    assert "should be at least 8 character(s)" in errors_on(changeset).idempotency_key
    assert "should be at least 16 character(s)" in errors_on(changeset).request_nonce
  end

  test "bounds audit context and requires JSON-safe values" do
    too_large = String.duplicate("x", 16_385)

    assert {:error, large_changeset} =
             valid_attributes()
             |> Map.put(:request_context, %{"value" => too_large})
             |> ConfirmedRequest.new()

    assert "is too large" in errors_on(large_changeset).request_context

    assert {:error, invalid_changeset} =
             valid_attributes()
             |> Map.put(:request_context, %{"value" => self()})
             |> ConfirmedRequest.new()

    assert "must be valid JSON data" in errors_on(invalid_changeset).request_context
  end

  defp valid_attributes do
    %{
      entitlement_allocation_id: Ecto.UUID.generate(),
      validation_point_id: Ecto.UUID.generate(),
      device_installation_id: Ecto.UUID.generate(),
      idempotency_key: "redeem:request-123",
      request_nonce: "opaque-request-nonce-123",
      request_context: %{"channel" => "mobile"}
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
