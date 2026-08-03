defmodule Clubeira.Tenancy.RepoScopeTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Polos.Polo
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  test "database tests execute as a role that cannot bypass RLS", %{database_role: role} do
    assert %{rows: [[^role, false, false]]} =
             Repo.query!("""
             SELECT rolname, rolsuper, rolbypassrls
             FROM pg_roles
             WHERE rolname = current_user
             """)
  end

  test "scopes tenant reads and restores connection metadata afterwards" do
    city_a = insert(:city)
    city_b = insert(:city)
    scope_a = Scope.new!(Ecto.UUID.generate())
    scope_b = Scope.new!(Ecto.UUID.generate())

    polo_a = insert_polo!(scope_a, city_a, "scope-a")
    polo_b = insert_polo!(scope_b, city_b, "scope-b")

    assert Repo.all(Polo) == []

    assert {:ok, [visible_a]} =
             Repo.transact_in_polo(scope_a, fn -> {:ok, Repo.all(Polo)} end)

    assert {:ok, [visible_b]} =
             Repo.transact_in_polo(scope_b, fn -> {:ok, Repo.all(Polo)} end)

    assert visible_a.id == polo_a.id
    assert visible_b.id == polo_b.id

    assert %{rows: [[nil_or_empty]]} =
             Repo.query!("SELECT current_setting('app.current_polo_id', true)")

    assert nil_or_empty in [nil, ""]
  end

  test "rejects switching polo inside an already scoped transaction" do
    scope_a = Scope.new!(Ecto.UUID.generate())
    scope_b = Scope.new!(Ecto.UUID.generate())

    assert {:error, {:tenant_scope_mismatch, :polo_id}} =
             Repo.transact_in_polo(scope_a, fn ->
               Repo.transact_in_polo(scope_b, fn -> {:ok, :unreachable} end)
             end)
  end

  test "restores connection metadata when a scoped operation raises" do
    scope = Scope.new!(Ecto.UUID.generate(), request_id: Ecto.UUID.generate())

    assert {:ok, :restored} =
             Repo.transact(fn ->
               assert_raise RuntimeError, "scoped failure", fn ->
                 Repo.transact_in_polo(scope, fn -> raise "scoped failure" end)
               end

               assert %{rows: [[polo_id, actor_user_id, request_id]]} =
                        Repo.query!("""
                        SELECT
                          current_setting('app.current_polo_id', true),
                          current_setting('app.current_actor_user_id', true),
                          current_setting('app.current_request_id', true)
                        """)

               assert polo_id in [nil, ""]
               assert actor_user_id in [nil, ""]
               assert request_id in [nil, ""]

               {:ok, :restored}
             end)
  end

  test "preserves the original database error when scope restoration cannot query" do
    scope = Scope.new!(Ecto.UUID.generate())

    assert_raise Postgrex.Error, ~r/relation "missing_scoped_table" does not exist/, fn ->
      Repo.transact(fn ->
        Repo.transact_in_polo(scope, fn ->
          Repo.query!("SELECT * FROM missing_scoped_table")
        end)
      end)
    end
  end

  test "RLS rejects a row whose polo differs from the active scope" do
    city = insert(:city)
    scope = Scope.new!(Ecto.UUID.generate())

    assert_raise Postgrex.Error, fn ->
      Repo.transact_in_polo(scope, fn ->
        Repo.insert!(%Polo{
          id: Ecto.UUID.generate(),
          city: city,
          name: "Forged Polo",
          timezone: "America/Sao_Paulo",
          status: "active"
        })

        {:ok, :unreachable}
      end)
    end
  end

  defp insert_polo!(scope, city, slug) do
    assert {:ok, polo} =
             Repo.transact_in_polo(scope, fn ->
               polo =
                 Repo.insert!(%Polo{
                   id: scope.polo_id,
                   city: city,
                   name: slug,
                   timezone: "America/Sao_Paulo",
                   status: "active"
                 })

               {:ok, polo}
             end)

    polo
  end
end
