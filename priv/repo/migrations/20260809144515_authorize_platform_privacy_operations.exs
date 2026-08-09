defmodule Clubeira.Repo.Migrations.AuthorizePlatformPrivacyOperations do
  use Ecto.Migration

  def up do
    execute("""
    CREATE POLICY privacy_requests_platform_select ON privacy_requests
    FOR SELECT
    USING (#{privacy_officer_sql()})
    """)

    execute("""
    CREATE POLICY privacy_requests_platform_update ON privacy_requests
    FOR UPDATE
    USING (#{privacy_officer_sql()})
    WITH CHECK (#{privacy_officer_sql()})
    """)

    execute("""
    CREATE POLICY privacy_request_events_platform_select ON privacy_request_events
    FOR SELECT
    USING (#{privacy_officer_sql()})
    """)

    execute("""
    CREATE POLICY privacy_request_events_platform_insert ON privacy_request_events
    FOR INSERT
    WITH CHECK (#{privacy_officer_sql()})
    """)

    execute("""
    CREATE POLICY privacy_consent_events_platform_select ON privacy_consent_events
    FOR SELECT
    USING (#{privacy_officer_sql()})
    """)
  end

  def down do
    execute(
      "DROP POLICY IF EXISTS privacy_consent_events_platform_select ON privacy_consent_events"
    )

    execute(
      "DROP POLICY IF EXISTS privacy_request_events_platform_insert ON privacy_request_events"
    )

    execute(
      "DROP POLICY IF EXISTS privacy_request_events_platform_select ON privacy_request_events"
    )

    execute("DROP POLICY IF EXISTS privacy_requests_platform_update ON privacy_requests")
    execute("DROP POLICY IF EXISTS privacy_requests_platform_select ON privacy_requests")
  end

  defp privacy_officer_sql do
    """
    EXISTS (
      SELECT 1
      FROM organization_memberships AS membership
      JOIN organizations AS organization
        ON organization.id = membership.organization_id
      JOIN organization_membership_roles AS membership_role
        ON membership_role.organization_id = membership.organization_id
       AND membership_role.organization_membership_id = membership.id
      JOIN organization_roles AS role
        ON role.id = membership_role.organization_role_id
       AND role.organization_id = membership_role.organization_id
      WHERE membership.user_id =
              NULLIF(current_setting('app.current_actor_user_id', true), '')::uuid
        AND membership.status = 'active'
        AND membership.valid_during @> statement_timestamp()
        AND organization.kind = 'platform'
        AND organization.status = 'active'
        AND role.status = 'active'
        AND role.key IN ('privacy_officer', 'platform_admin')
    )
    """
  end
end
