defmodule Clubeira.Repo.RuntimeRoleTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Repo
  alias Clubeira.Repo.RuntimeRole

  test "accepts a role that cannot bypass RLS" do
    assert :ok = RuntimeRole.validate_repo!(Repo)
  end

  test "rejects a superuser runtime connection", %{database_role: database_role} do
    Repo.query!("RESET ROLE")

    try do
      assert_raise RuntimeError, ~r/unsafe Clubeira runtime database role/, fn ->
        RuntimeRole.validate_repo!(Repo)
      end
    after
      Repo.query!("SET LOCAL ROLE #{database_role}")
    end
  end
end
