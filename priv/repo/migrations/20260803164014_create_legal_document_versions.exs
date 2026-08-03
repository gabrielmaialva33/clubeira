defmodule Clubeira.Repo.Migrations.CreateLegalDocumentVersions do
  use Ecto.Migration

  def change do
    create table(:legal_document_versions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")

      add :legal_document_id, references(:legal_documents, type: :uuid, on_delete: :restrict),
        null: false

      add :version, :integer, null: false
      add :locale, :text, null: false
      add :content_uri, :text, null: false
      add :content_sha256, :binary, null: false
      add :effective_during, :tstzrange, null: false
      add :published_at, :timestamptz, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:legal_document_versions, [:legal_document_id, :locale, :version],
             name: :legal_document_versions_number_uidx
           )

    create constraint(:legal_document_versions, :legal_document_versions_version_check,
             check: "version > 0"
           )

    create constraint(:legal_document_versions, :legal_document_versions_range_check,
             check:
               "NOT isempty(effective_during) AND NOT lower_inf(effective_during) AND lower_inc(effective_during) AND NOT upper_inc(effective_during)"
           )

    create constraint(:legal_document_versions, :legal_document_versions_no_overlap,
             exclude: "gist (legal_document_id WITH =, locale WITH =, effective_during WITH &&)"
           )
  end
end
