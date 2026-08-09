defmodule Clubeira.Privacy.DatabaseContractTest do
  use Clubeira.DataCase, async: true

  alias Clubeira.Repo

  @actor_tables ~w(privacy_consent_events privacy_request_events privacy_requests)

  test "privacy evidence is actor-scoped, forced through RLS and append-only" do
    assert %{rows: rls_rows} =
             Repo.query!(
               """
               SELECT class.relname, class.relrowsecurity, class.relforcerowsecurity
               FROM pg_class AS class
               JOIN pg_namespace AS namespace ON namespace.oid = class.relnamespace
               WHERE namespace.nspname = 'public'
                 AND class.relname = ANY($1::text[])
               ORDER BY class.relname
               """,
               [@actor_tables]
             )

    assert rls_rows == Enum.map(@actor_tables, &[&1, true, true])

    assert %{rows: trigger_rows} =
             Repo.query!("""
             SELECT table_class.relname, trigger.tgname
             FROM pg_trigger AS trigger
             JOIN pg_class AS table_class ON table_class.oid = trigger.tgrelid
             WHERE table_class.relname IN ('privacy_consent_events', 'privacy_request_events')
               AND trigger.tgname IN (
                 'privacy_consent_events_append_only',
                 'privacy_request_events_append_only'
               )
               AND NOT trigger.tgisinternal
             ORDER BY table_class.relname
             """)

    assert trigger_rows == [
             ["privacy_consent_events", "privacy_consent_events_append_only"],
             ["privacy_request_events", "privacy_request_events_append_only"]
           ]
  end

  test "platform privacy officers have explicit read and lifecycle policies" do
    assert %{rows: rows} =
             Repo.query!("""
             SELECT class.relname, policy.polname, policy.polcmd
             FROM pg_policy AS policy
             JOIN pg_class AS class ON class.oid = policy.polrelid
             WHERE policy.polname LIKE '%_platform_%'
               AND class.relname IN (
                 'privacy_consent_events',
                 'privacy_request_events',
                 'privacy_requests'
               )
             ORDER BY class.relname, policy.polname
             """)

    assert rows == [
             ["privacy_consent_events", "privacy_consent_events_platform_select", "r"],
             ["privacy_request_events", "privacy_request_events_platform_insert", "a"],
             ["privacy_request_events", "privacy_request_events_platform_select", "r"],
             ["privacy_requests", "privacy_requests_platform_select", "r"],
             ["privacy_requests", "privacy_requests_platform_update", "w"]
           ]
  end

  test "requests have durable replay, deadline and terminal-state invariants" do
    constraints = constraint_definitions()

    assert constraints["processing_purposes_consent_document_check"] =~
             "legal_document_version_id IS NOT NULL"

    assert constraints["privacy_consent_events_purpose_document_fkey"] =~
             "FOREIGN KEY (processing_purpose_id, legal_document_version_id)"

    assert constraints["privacy_consent_events_purpose_document_fkey"] =~
             "REFERENCES processing_purposes(id, legal_document_version_id)"

    assert constraints["privacy_requests_hash_check"] =~ "octet_length(request_sha256) = 32"
    assert constraints["privacy_requests_due_at_check"] =~ "due_at > inserted_at"
    assert constraints["privacy_requests_lifecycle_check"] =~ "partially_completed"
    assert constraints["privacy_requests_rejection_check"] =~ "rejection_reason IS NOT NULL"
    assert constraints["privacy_request_events_type_check"] =~ "processing_started"

    assert %{rows: [[index_definition]]} =
             Repo.query!("""
             SELECT indexdef
             FROM pg_indexes
             WHERE schemaname = 'public'
               AND indexname = 'privacy_requests_actor_client_request_uidx'
             """)

    assert index_definition =~ "(requester_user_id, client_request_id)"
  end

  defp constraint_definitions do
    %{rows: rows} =
      Repo.query!("""
      SELECT constraint_record.conname, pg_get_constraintdef(constraint_record.oid)
      FROM pg_constraint AS constraint_record
      WHERE constraint_record.conname IN (
        'processing_purposes_consent_document_check',
        'privacy_consent_events_purpose_document_fkey',
        'privacy_requests_hash_check',
        'privacy_requests_due_at_check',
        'privacy_requests_lifecycle_check',
        'privacy_requests_rejection_check',
        'privacy_request_events_type_check'
      )
      """)

    Map.new(rows, fn [name, definition] -> {name, definition} end)
  end
end
