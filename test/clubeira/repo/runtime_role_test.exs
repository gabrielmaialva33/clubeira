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

  test "rejects a runtime role missing required table privileges", %{
    database_role: database_role
  } do
    Repo.query!("RESET ROLE")

    try do
      Repo.query!("REVOKE DELETE ON cities FROM #{database_role}")
      Repo.query!("SET LOCAL ROLE #{database_role}")

      assert_raise RuntimeError, ~r/has_required_table_privileges=false/, fn ->
        RuntimeRole.validate_repo!(Repo)
      end
    after
      Repo.query!("RESET ROLE")
      Repo.query!("GRANT DELETE ON cities TO #{database_role}")
      Repo.query!("SET LOCAL ROLE #{database_role}")
    end
  end

  test "rejects a runtime role that can mutate migration metadata", %{
    database_role: database_role
  } do
    Repo.query!("RESET ROLE")

    try do
      Repo.query!("GRANT INSERT ON schema_migrations TO #{database_role}")
      Repo.query!("SET LOCAL ROLE #{database_role}")

      assert_raise RuntimeError, ~r/migration_metadata_is_read_only=false/, fn ->
        RuntimeRole.validate_repo!(Repo)
      end
    after
      Repo.query!("RESET ROLE")
      Repo.query!("REVOKE INSERT ON schema_migrations FROM #{database_role}")
      Repo.query!("SET LOCAL ROLE #{database_role}")
    end
  end

  test "rejects a restricted role that owns an application table", %{
    database_role: database_role
  } do
    owner_role = "clubeira_owner_probe_#{System.unique_integer([:positive, :monotonic])}"

    Repo.query!("RESET ROLE")

    try do
      Repo.query!(
        "CREATE ROLE #{owner_role} NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS"
      )

      Repo.query!("GRANT USAGE ON SCHEMA public TO #{owner_role}")
      Repo.query!("CREATE TABLE runtime_role_owner_probe (id integer)")
      Repo.query!("ALTER TABLE runtime_role_owner_probe OWNER TO #{owner_role}")
      Repo.query!("SET LOCAL ROLE #{owner_role}")

      assert_raise RuntimeError, ~r/owns_or_can_assume_application_table_owner=true/, fn ->
        RuntimeRole.validate_repo!(Repo)
      end
    after
      Repo.query!("RESET ROLE")
      Repo.query!("DROP TABLE IF EXISTS runtime_role_owner_probe")
      Repo.query!("DROP OWNED BY #{owner_role}")
      Repo.query!("DROP ROLE IF EXISTS #{owner_role}")
      Repo.query!("SET LOCAL ROLE #{database_role}")
    end
  end

  test "rejects a role that can assume an application table owner", %{
    database_role: database_role
  } do
    owner_role = "clubeira_owner_member_probe_#{System.unique_integer([:positive, :monotonic])}"

    Repo.query!("RESET ROLE")

    try do
      Repo.query!(
        "CREATE ROLE #{owner_role} NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS"
      )

      Repo.query!("CREATE TABLE runtime_role_owner_member_probe (id integer)")
      Repo.query!("ALTER TABLE runtime_role_owner_member_probe OWNER TO #{owner_role}")
      Repo.query!("GRANT #{owner_role} TO #{database_role}")
      Repo.query!("SET LOCAL ROLE #{database_role}")

      assert_raise RuntimeError, ~r/owns_or_can_assume_application_table_owner=true/, fn ->
        RuntimeRole.validate_repo!(Repo)
      end
    after
      Repo.query!("RESET ROLE")
      Repo.query!("REVOKE #{owner_role} FROM #{database_role}")
      Repo.query!("DROP TABLE IF EXISTS runtime_role_owner_member_probe")
      Repo.query!("DROP OWNED BY #{owner_role}")
      Repo.query!("DROP ROLE IF EXISTS #{owner_role}")
      Repo.query!("SET LOCAL ROLE #{database_role}")
    end
  end
end
