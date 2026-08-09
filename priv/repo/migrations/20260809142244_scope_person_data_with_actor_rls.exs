defmodule Clubeira.Repo.Migrations.ScopePersonDataWithActorRls do
  use Ecto.Migration

  @actor_id "NULLIF(current_setting('app.current_actor_user_id', true), '')::uuid"

  def up do
    create unique_index(:user_person_links, [:user_id],
             where: "relationship = 'self' AND status = 'active'",
             name: :user_person_links_active_self_user_uidx
           )

    execute("ALTER TABLE user_person_links ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE user_person_links FORCE ROW LEVEL SECURITY")

    execute("""
    CREATE POLICY user_person_links_actor_scope ON user_person_links
    FOR ALL
    USING (user_id = #{@actor_id})
    WITH CHECK (user_id = #{@actor_id})
    """)

    execute("ALTER TABLE persons ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE persons FORCE ROW LEVEL SECURITY")

    execute("""
    CREATE POLICY persons_actor_select ON persons
    FOR SELECT
    USING (#{owned_person_sql("persons.id")})
    """)

    execute("""
    CREATE POLICY persons_actor_insert ON persons
    FOR INSERT
    WITH CHECK (#{@actor_id} IS NOT NULL)
    """)

    execute("""
    CREATE POLICY persons_actor_update ON persons
    FOR UPDATE
    USING (#{owned_person_sql("persons.id")})
    WITH CHECK (#{owned_person_sql("persons.id")})
    """)

    Enum.each(~w(person_identifiers person_contact_points), fn table ->
      execute("ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY")
      execute("ALTER TABLE #{table} FORCE ROW LEVEL SECURITY")

      execute("""
      CREATE POLICY #{table}_actor_scope ON #{table}
      FOR ALL
      USING (#{owned_person_sql("#{table}.person_id")})
      WITH CHECK (#{owned_person_sql("#{table}.person_id")})
      """)
    end)
  end

  def down do
    Enum.each(Enum.reverse(~w(person_identifiers person_contact_points)), fn table ->
      execute("DROP POLICY IF EXISTS #{table}_actor_scope ON #{table}")
      execute("ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY")
      execute("ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY")
    end)

    execute("DROP POLICY IF EXISTS persons_actor_update ON persons")
    execute("DROP POLICY IF EXISTS persons_actor_insert ON persons")
    execute("DROP POLICY IF EXISTS persons_actor_select ON persons")
    execute("ALTER TABLE persons NO FORCE ROW LEVEL SECURITY")
    execute("ALTER TABLE persons DISABLE ROW LEVEL SECURITY")

    execute("DROP POLICY IF EXISTS user_person_links_actor_scope ON user_person_links")
    execute("ALTER TABLE user_person_links NO FORCE ROW LEVEL SECURITY")
    execute("ALTER TABLE user_person_links DISABLE ROW LEVEL SECURITY")

    drop index(:user_person_links, [:user_id], name: :user_person_links_active_self_user_uidx)
  end

  defp owned_person_sql(person_id) do
    """
    EXISTS (
      SELECT 1
      FROM user_person_links
      WHERE user_person_links.person_id = #{person_id}
        AND user_person_links.user_id = #{@actor_id}
        AND user_person_links.status = 'active'
    )
    """
  end
end
