defmodule Clubeira.Repo.Migrations.CreateUserContractPoloRoutes do
  use Ecto.Migration

  def up do
    create table(:user_contract_polo_routes, primary_key: false) do
      add :user_id, references(:users, type: :uuid, on_delete: :restrict),
        primary_key: true,
        null: false

      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict),
        primary_key: true,
        null: false

      add :first_contract_at, :timestamptz, null: false
    end

    create index(:user_contract_polo_routes, [:polo_id])

    execute("ALTER TABLE user_contract_polo_routes ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE user_contract_polo_routes FORCE ROW LEVEL SECURITY")

    execute("""
    CREATE POLICY user_contract_polo_routes_actor_read
    ON user_contract_polo_routes
    FOR SELECT
    USING (
      user_id = NULLIF(current_setting('app.current_actor_user_id', true), '')::uuid
    )
    """)

    execute("""
    CREATE POLICY user_contract_polo_routes_owner_insert
    ON user_contract_polo_routes
    FOR INSERT
    WITH CHECK (
      current_user = pg_get_userbyid(
        (
          SELECT relowner
          FROM pg_class
          WHERE oid = 'public.user_contract_polo_routes'::regclass
        )
      )
    )
    """)

    execute("""
    CREATE POLICY user_contract_polo_routes_owner_delete
    ON user_contract_polo_routes
    FOR DELETE
    USING (
      current_user = pg_get_userbyid(
        (
          SELECT relowner
          FROM pg_class
          WHERE oid = 'public.user_contract_polo_routes'::regclass
        )
      )
    )
    """)

    execute("""
    CREATE FUNCTION maintain_user_contract_polo_route()
    RETURNS trigger
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = public, pg_temp
    AS $$
    BEGIN
      BEGIN
        INSERT INTO user_contract_polo_routes (user_id, polo_id, first_contract_at)
        VALUES (NEW.purchaser_user_id, NEW.polo_id, NEW.inserted_at);
      EXCEPTION
        WHEN unique_violation THEN
          NULL;
      END;

      RETURN NEW;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER access_contracts_user_polo_route
    AFTER INSERT OR UPDATE OF purchaser_user_id, polo_id
    ON access_contracts
    FOR EACH ROW
    EXECUTE FUNCTION maintain_user_contract_polo_route()
    """)
  end

  def down do
    execute("DROP TRIGGER access_contracts_user_polo_route ON access_contracts")
    execute("DROP FUNCTION maintain_user_contract_polo_route()")
    drop table(:user_contract_polo_routes)
  end
end
