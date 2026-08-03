defmodule Clubeira.Repo.Migrations.CreatePrivacyRequests do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:privacy_requests, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :requester_user_id, references(:users, type: :uuid, on_delete: :restrict), null: false
      add :person_id, references(:persons, type: :uuid, on_delete: :restrict), null: false
      add :request_type, :text, null: false
      add :status, :text, null: false, default: "received"
      add :due_at, :timestamptz, null: false
      add :completed_at, :timestamptz
      add :rejection_reason, :text

      timestamps(@timestamps_opts)
    end

    create index(:privacy_requests, [:status, :due_at])
    create index(:privacy_requests, [:person_id, :inserted_at])

    create constraint(:privacy_requests, :privacy_requests_type_check,
             check:
               "request_type IN ('access', 'confirmation', 'correction', 'portability', 'deletion', 'anonymization', 'consent_withdrawal', 'information')"
           )

    create constraint(:privacy_requests, :privacy_requests_status_check,
             check:
               "status IN ('received', 'identity_verification', 'in_progress', 'completed', 'partially_completed', 'rejected', 'cancelled')"
           )
  end
end
