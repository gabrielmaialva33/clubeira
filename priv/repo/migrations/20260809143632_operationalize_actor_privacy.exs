defmodule Clubeira.Repo.Migrations.OperationalizeActorPrivacy do
  use Ecto.Migration

  @actor_id "NULLIF(current_setting('app.current_actor_user_id', true), '')::uuid"

  def up do
    alter table(:processing_purposes) do
      add :legal_document_version_id,
          references(:legal_document_versions, type: :uuid, on_delete: :restrict)
    end

    create constraint(:processing_purposes, :processing_purposes_consent_document_check,
             check: "legal_basis <> 'consent' OR legal_document_version_id IS NOT NULL"
           )

    create unique_index(:processing_purposes, [:id, :legal_document_version_id],
             name: :processing_purposes_document_identity_uidx
           )

    execute("""
    ALTER TABLE privacy_consent_events
    ADD CONSTRAINT privacy_consent_events_purpose_document_fkey
    FOREIGN KEY (processing_purpose_id, legal_document_version_id)
    REFERENCES processing_purposes (id, legal_document_version_id)
    ON DELETE RESTRICT
    """)

    alter table(:privacy_requests) do
      add :client_request_id, :uuid, null: false
      add :request_sha256, :binary, null: false
    end

    create unique_index(:privacy_requests, [:requester_user_id, :client_request_id],
             name: :privacy_requests_actor_client_request_uidx
           )

    create constraint(:privacy_requests, :privacy_requests_hash_check,
             check: "octet_length(request_sha256) = 32"
           )

    create constraint(:privacy_requests, :privacy_requests_due_at_check,
             check: "due_at > inserted_at"
           )

    create constraint(:privacy_requests, :privacy_requests_lifecycle_check,
             check: """
             (
               status IN ('completed', 'partially_completed', 'rejected', 'cancelled')
               AND completed_at IS NOT NULL
             ) OR (
               status IN ('received', 'identity_verification', 'in_progress')
               AND completed_at IS NULL
             )
             """
           )

    create constraint(:privacy_requests, :privacy_requests_rejection_check,
             check: """
             (status = 'rejected' AND rejection_reason IS NOT NULL AND btrim(rejection_reason) <> '')
             OR (status <> 'rejected' AND rejection_reason IS NULL)
             """
           )

    create constraint(:privacy_request_events, :privacy_request_events_type_check,
             check:
               "event_type IN ('received', 'identity_verification_started', 'processing_started', 'completed', 'partially_completed', 'rejected', 'cancelled')"
           )

    enable_actor_rls()
  end

  def down do
    disable_actor_rls()

    drop_if_exists constraint(:privacy_request_events, :privacy_request_events_type_check)
    drop_if_exists constraint(:privacy_requests, :privacy_requests_rejection_check)
    drop_if_exists constraint(:privacy_requests, :privacy_requests_lifecycle_check)
    drop_if_exists constraint(:privacy_requests, :privacy_requests_due_at_check)
    drop_if_exists constraint(:privacy_requests, :privacy_requests_hash_check)

    drop index(:privacy_requests, [:requester_user_id, :client_request_id],
           name: :privacy_requests_actor_client_request_uidx
         )

    alter table(:privacy_requests) do
      remove_if_exists :request_sha256
      remove_if_exists :client_request_id
    end

    drop_if_exists constraint(
                     :privacy_consent_events,
                     :privacy_consent_events_purpose_document_fkey
                   )

    drop_if_exists index(:processing_purposes, [:id, :legal_document_version_id],
                     name: :processing_purposes_document_identity_uidx
                   )

    drop_if_exists constraint(
                     :processing_purposes,
                     :processing_purposes_consent_document_check
                   )

    alter table(:processing_purposes) do
      remove_if_exists :legal_document_version_id
    end
  end

  defp enable_actor_rls do
    execute("ALTER TABLE privacy_consent_events ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE privacy_consent_events FORCE ROW LEVEL SECURITY")

    execute("""
    CREATE POLICY privacy_consent_events_actor_scope ON privacy_consent_events
    FOR ALL
    USING (user_id = #{@actor_id})
    WITH CHECK (user_id = #{@actor_id})
    """)

    execute("ALTER TABLE privacy_requests ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE privacy_requests FORCE ROW LEVEL SECURITY")

    execute("""
    CREATE POLICY privacy_requests_actor_scope ON privacy_requests
    FOR ALL
    USING (requester_user_id = #{@actor_id})
    WITH CHECK (requester_user_id = #{@actor_id})
    """)

    execute("ALTER TABLE privacy_request_events ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE privacy_request_events FORCE ROW LEVEL SECURITY")

    execute("""
    CREATE POLICY privacy_request_events_actor_scope ON privacy_request_events
    FOR ALL
    USING (#{owned_request_sql()})
    WITH CHECK (#{owned_request_sql()})
    """)
  end

  defp disable_actor_rls do
    Enum.each(~w(privacy_request_events privacy_requests privacy_consent_events), fn table ->
      execute("DROP POLICY IF EXISTS #{table}_actor_scope ON #{table}")
      execute("ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY")
      execute("ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY")
    end)
  end

  defp owned_request_sql do
    """
    EXISTS (
      SELECT 1
      FROM privacy_requests
      WHERE privacy_requests.id = privacy_request_events.privacy_request_id
        AND privacy_requests.requester_user_id = #{@actor_id}
    )
    """
  end
end
