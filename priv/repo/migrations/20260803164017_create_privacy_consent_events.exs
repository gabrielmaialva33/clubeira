defmodule Clubeira.Repo.Migrations.CreatePrivacyConsentEvents do
  use Ecto.Migration

  def change do
    create table(:privacy_consent_events, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")

      add :processing_purpose_id,
          references(:processing_purposes, type: :uuid, on_delete: :restrict), null: false

      add :legal_document_version_id,
          references(:legal_document_versions, type: :uuid, on_delete: :restrict), null: false

      add :person_id, references(:persons, type: :uuid, on_delete: :restrict), null: false
      add :user_id, references(:users, type: :uuid, on_delete: :restrict), null: false
      add :event_type, :text, null: false
      add :occurred_at, :timestamptz, null: false
      add :evidence, :map, null: false, default: %{}
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:privacy_consent_events, [:person_id, :processing_purpose_id, :occurred_at],
             name: :privacy_consent_events_timeline_idx
           )

    create constraint(:privacy_consent_events, :privacy_consent_events_type_check,
             check: "event_type IN ('granted', 'withdrawn')"
           )
  end
end
