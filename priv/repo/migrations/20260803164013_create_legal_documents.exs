defmodule Clubeira.Repo.Migrations.CreateLegalDocuments do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:legal_documents, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :code, :citext, null: false
      add :document_kind, :text, null: false
      add :audience, :text, null: false
      add :status, :text, null: false, default: "draft"

      timestamps(@timestamps_opts)
    end

    create unique_index(:legal_documents, [:code])

    create constraint(:legal_documents, :legal_documents_kind_check,
             check:
               "document_kind IN ('terms_of_service', 'privacy_notice', 'consent_notice', 'partner_terms')"
           )

    create constraint(:legal_documents, :legal_documents_audience_check,
             check: "audience IN ('consumer', 'partner', 'staff', 'public')"
           )

    create constraint(:legal_documents, :legal_documents_status_check,
             check: "status IN ('draft', 'active', 'retired')"
           )
  end
end
