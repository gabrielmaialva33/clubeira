defmodule Clubeira.Repo.Migrations.ExposeClientAccessBootstrapReads do
  use Ecto.Migration

  def up do
    execute("""
    CREATE POLICY polo_memberships_actor_read ON polo_memberships
    FOR SELECT
    USING (
      user_id = NULLIF(current_setting('app.current_actor_user_id', true), '')::uuid
    )
    """)

    execute("""
    CREATE POLICY polo_membership_roles_actor_read ON polo_membership_roles
    FOR SELECT
    USING (
      EXISTS (
        SELECT 1
        FROM polo_memberships AS membership
        WHERE membership.id = polo_membership_roles.polo_membership_id
          AND membership.polo_id = polo_membership_roles.polo_id
          AND membership.user_id =
            NULLIF(current_setting('app.current_actor_user_id', true), '')::uuid
      )
    )
    """)

    execute("""
    CREATE POLICY polo_roles_actor_read ON polo_roles
    FOR SELECT
    USING (
      EXISTS (
        SELECT 1
        FROM polo_membership_roles AS assignment
        JOIN polo_memberships AS membership
          ON membership.id = assignment.polo_membership_id
         AND membership.polo_id = assignment.polo_id
        WHERE assignment.polo_role_id = polo_roles.id
          AND assignment.polo_id = polo_roles.polo_id
          AND membership.user_id =
            NULLIF(current_setting('app.current_actor_user_id', true), '')::uuid
      )
    )
    """)

    execute("""
    CREATE POLICY polos_staff_actor_read ON polos
    FOR SELECT
    USING (
      EXISTS (
        SELECT 1
        FROM polo_memberships AS membership
        WHERE membership.polo_id = polos.id
          AND membership.user_id =
            NULLIF(current_setting('app.current_actor_user_id', true), '')::uuid
      )
    )
    """)

    execute("""
    CREATE POLICY polos_public_active_read ON polos
    FOR SELECT
    USING (status = 'active')
    """)
  end

  def down do
    execute("DROP POLICY IF EXISTS polos_public_active_read ON polos")
    execute("DROP POLICY IF EXISTS polos_staff_actor_read ON polos")
    execute("DROP POLICY IF EXISTS polo_roles_actor_read ON polo_roles")
    execute("DROP POLICY IF EXISTS polo_membership_roles_actor_read ON polo_membership_roles")
    execute("DROP POLICY IF EXISTS polo_memberships_actor_read ON polo_memberships")
  end
end
