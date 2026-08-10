defmodule Clubeira.Operations.BoundaryTest do
  use ExUnit.Case, async: true

  alias Clubeira.Operations
  alias Clubeira.Tenancy.Scope

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
