defmodule Clubeira.Repo.Migrations.InstallAuditAppendOnlyTriggers do
  use Ecto.Migration

  def change do
    [
      {"partner_agreement_terms", "partner_agreement_terms_append_only"},
      {"polo_policy_versions", "polo_policy_versions_append_only"},
      {"contract_events", "contract_events_append_only"},
      {"legal_document_versions", "legal_document_versions_append_only"},
      {"legal_acceptances", "legal_acceptances_append_only"},
      {"privacy_consent_events", "privacy_consent_events_append_only"},
      {"privacy_request_events", "privacy_request_events_append_only"},
      {"tenant_audit_events", "tenant_audit_events_append_only"},
      {"system_audit_events", "system_audit_events_append_only"},
      {"domain_events", "domain_events_append_only"}
    ]
    |> Enum.each(fn {table, trigger} ->
      execute(
        """
        CREATE TRIGGER #{trigger}
        BEFORE UPDATE OR DELETE ON #{table}
        FOR EACH ROW
        EXECUTE FUNCTION clubeira_reject_immutable_mutation();
        """,
        "DROP TRIGGER #{trigger} ON #{table}"
      )
    end)
  end
end
