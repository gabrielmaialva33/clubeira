defmodule Clubeira.Tenancy.ScopeTest do
  use ExUnit.Case, async: true

  alias Clubeira.Tenancy.Scope

  test "builds a normalized scope with actor metadata" do
    polo_id = Ecto.UUID.generate()
    actor_user_id = Ecto.UUID.generate()
    request_id = Ecto.UUID.generate()

    assert {:ok, scope} =
             Scope.new(polo_id,
               actor_user_id: actor_user_id,
               request_id: request_id,
               roles: ["operator", "operator", "manager"]
             )

    assert scope.polo_id == polo_id
    assert scope.actor_user_id == actor_user_id
    assert scope.request_id == request_id
    assert scope.roles == ["operator", "manager"]
  end

  test "rejects malformed identifiers, roles, and options" do
    polo_id = Ecto.UUID.generate()

    assert {:error, :invalid_polo_id} = Scope.new("not-a-uuid")
    assert {:error, :invalid_actor_user_id} = Scope.new(polo_id, actor_user_id: "invalid")
    assert {:error, :invalid_request_id} = Scope.new(polo_id, request_id: "invalid")
    assert {:error, :invalid_roles} = Scope.new(polo_id, roles: [:operator])
    assert {:error, :invalid_options} = Scope.new(polo_id, unknown: true)
    assert_raise ArgumentError, fn -> Scope.new!("not-a-uuid") end
  end
end
