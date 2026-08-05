defmodule Clubeira.Repo.Migrations.ScopeActorOwnedDataWithRls do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE user_device_authorizations ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE user_device_authorizations FORCE ROW LEVEL SECURITY")

    execute(
      "DROP POLICY IF EXISTS user_device_authorizations_actor_scope ON user_device_authorizations"
    )

    execute("""
    CREATE POLICY user_device_authorizations_actor_scope ON user_device_authorizations
    FOR ALL
    USING (
      user_id = NULLIF(current_setting('app.current_actor_user_id', true), '')::uuid
    )
    WITH CHECK (
      user_id = NULLIF(current_setting('app.current_actor_user_id', true), '')::uuid
    )
    """)

    execute("DROP POLICY IF EXISTS legal_acceptances_scope ON legal_acceptances")
    execute("DROP POLICY IF EXISTS polo_isolation ON legal_acceptances")
    execute("ALTER TABLE legal_acceptances ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE legal_acceptances FORCE ROW LEVEL SECURITY")

    execute("""
    CREATE POLICY legal_acceptances_scope ON legal_acceptances
    FOR ALL
    USING (
      polo_id = NULLIF(current_setting('app.current_polo_id', true), '')::uuid
      OR (
        polo_id IS NULL
        AND user_id = NULLIF(current_setting('app.current_actor_user_id', true), '')::uuid
      )
    )
    WITH CHECK (
      polo_id = NULLIF(current_setting('app.current_polo_id', true), '')::uuid
      OR (
        polo_id IS NULL
        AND user_id = NULLIF(current_setting('app.current_actor_user_id', true), '')::uuid
      )
    )
    """)
  end

  def down do
    execute("DROP POLICY IF EXISTS legal_acceptances_scope ON legal_acceptances")

    execute("""
    CREATE POLICY polo_isolation ON legal_acceptances
    FOR ALL
    USING (
      polo_id = NULLIF(current_setting('app.current_polo_id', true), '')::uuid
    )
    WITH CHECK (
      polo_id = NULLIF(current_setting('app.current_polo_id', true), '')::uuid
    )
    """)

    execute(
      "DROP POLICY IF EXISTS user_device_authorizations_actor_scope ON user_device_authorizations"
    )

    execute("ALTER TABLE user_device_authorizations NO FORCE ROW LEVEL SECURITY")
    execute("ALTER TABLE user_device_authorizations DISABLE ROW LEVEL SECURITY")
  end
end
