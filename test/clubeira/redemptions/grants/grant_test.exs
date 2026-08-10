defmodule Clubeira.Redemptions.GrantTest do
  use ExUnit.Case, async: true

  alias Clubeira.Redemptions.Grant
  alias Clubeira.Tenancy.Scope

  test "grant expires quickly and is bound to one polo" do
    polo_id = Ecto.UUID.generate(version: 7)
    other_polo_id = Ecto.UUID.generate(version: 7)
    actor_user_id = Ecto.UUID.generate(version: 7)

    scope = Scope.new!(polo_id, actor_user_id: actor_user_id)

    current =
      Grant.issue(
        scope,
        Ecto.UUID.generate(version: 7),
        Ecto.UUID.generate(version: 7),
        DateTime.utc_now(:second)
      )

    assert {:ok, grant} = Grant.verify(current.token, polo_id)
    assert grant.actor_user_id == actor_user_id
    assert Grant.verify(current.token, other_polo_id) == {:error, :grant_invalid}

    expired =
      Grant.issue(
        scope,
        Ecto.UUID.generate(version: 7),
        Ecto.UUID.generate(version: 7),
        DateTime.add(DateTime.utc_now(:second), -121, :second)
      )

    assert Grant.verify(expired.token, polo_id) == {:error, :grant_invalid}
  end
end
