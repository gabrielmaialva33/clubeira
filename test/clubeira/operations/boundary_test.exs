defmodule Clubeira.Operations.BoundaryTest do
  use ExUnit.Case, async: true

  alias Clubeira.Operations
  alias Clubeira.Operations.OutboxRetryRequest
  alias Clubeira.Tenancy.Scope

  test "the outbox-retry form boundary rejects non-map and struct payloads without raising" do
    Enum.each([:invalid, %Clubeira.Operations.OutboxRetryRequest{}], fn attributes ->
      changeset = Operations.change_outbox_retry_request(attributes)

      refute changeset.valid?
      assert {:base, {"must be a map", []}} in changeset.errors
    end)
  end

  test "the outbox-retry command validates its external idempotency key" do
    assert {:ok, request} = OutboxRetryRequest.new(%{"idempotency_key" => "outbox-retry-001"})
    assert request.idempotency_key == "outbox-retry-001"

    for attributes <- [
          :invalid,
          %URI{},
          %{},
          %{"idempotency_key" => "short"},
          %{"idempotency_key" => "invalid key"}
        ] do
      assert {:error, changeset} = OutboxRetryRequest.new(attributes)
      refute changeset.valid?
    end
  end

  test "operational APIs fail closed before touching the database without an actor or scope" do
    polo_id = Ecto.UUID.generate(version: 7)
    service_scope = Scope.new!(polo_id)
    actor_scope = Scope.new!(polo_id, actor_user_id: Ecto.UUID.generate(version: 7))

    assert Operations.list_backoffice_audit_events(service_scope, %{}) ==
             {:error, :operations_admin_required}

    assert Operations.list_backoffice_outbox_messages(service_scope, %{}) ==
             {:error, :operations_admin_required}

    assert Operations.retry_outbox_message(service_scope, Ecto.UUID.generate(), %{}) ==
             {:error, :operations_admin_required}

    assert Operations.list_backoffice_audit_events(:invalid_scope, %{}) ==
             {:error, :operations_admin_required}

    assert Operations.list_backoffice_outbox_messages(:invalid_scope, %{}) ==
             {:error, :operations_admin_required}

    assert Operations.retry_outbox_message(:invalid_scope, Ecto.UUID.generate(), %{}) ==
             {:error, :operations_admin_required}

    assert Operations.retry_outbox_message(actor_scope, "not-a-uuid", %{}) ==
             {:error, :outbox_message_not_found}
  end
end
