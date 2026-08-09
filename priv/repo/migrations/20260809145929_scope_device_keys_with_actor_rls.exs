defmodule Clubeira.Repo.Migrations.ScopeDeviceKeysWithActorRls do
  use Ecto.Migration

  @actor_id "NULLIF(current_setting('app.current_actor_user_id', true), '')::uuid"

  def up do
    execute("ALTER TABLE device_keys ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE device_keys FORCE ROW LEVEL SECURITY")

    execute("""
    CREATE POLICY device_keys_actor_scope ON device_keys
    FOR ALL
    USING (#{authorized_device_sql()})
    WITH CHECK (#{authorized_device_sql()})
    """)
  end

  def down do
    execute("DROP POLICY IF EXISTS device_keys_actor_scope ON device_keys")
    execute("ALTER TABLE device_keys NO FORCE ROW LEVEL SECURITY")
    execute("ALTER TABLE device_keys DISABLE ROW LEVEL SECURITY")
  end

  defp authorized_device_sql do
    """
    EXISTS (
      SELECT 1
      FROM user_device_authorizations AS device_authorization
      WHERE device_authorization.device_installation_id = device_keys.device_installation_id
        AND device_authorization.user_id = #{@actor_id}
        AND device_authorization.status = 'active'
        AND device_authorization.revoked_at IS NULL
    )
    """
  end
end
