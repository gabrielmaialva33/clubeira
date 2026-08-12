defmodule Clubeira.Subscriptions.ContractLifecycleRequestTest do
  use ExUnit.Case, async: true

  alias Clubeira.Subscriptions.ContractLifecycleRequest

  test "normalizes a supported administrative transition" do
    assert {:ok, request} =
             ContractLifecycleRequest.new(%{
               action: " SUSPEND ",
               reason: "  Inadimplência confirmada.  ",
               idempotency_key: "contract-lifecycle-001"
             })

    assert request.action == "suspend"
    assert request.reason == "Inadimplência confirmada."
  end

  test "returns changesets for malformed boundary terms" do
    for attributes <- [:invalid, %ContractLifecycleRequest{}] do
      changeset = ContractLifecycleRequest.change(attributes)
      assert {:base, {"must be a map", []}} in changeset.errors

      assert {:error, changeset} = ContractLifecycleRequest.new(attributes)
      assert {:base, {"must be a map", []}} in changeset.errors
    end
  end

  test "rejects unsupported transitions and typed garbage" do
    for attributes <- [
          %{action: "cancel", reason: "Pedido inválido", idempotency_key: "contract-invalid-001"},
          %{action: 1, reason: 2, idempotency_key: "invalid key"}
        ] do
      assert {:error, changeset} = ContractLifecycleRequest.new(attributes)
      refute changeset.valid?
    end
  end
end
