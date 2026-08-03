defmodule Clubeira.Repo.Migrations.CreateLegalAcceptances do
  use Ecto.Migration

  def change do
    create table(:legal_acceptances, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")

      add :legal_document_version_id,
          references(:legal_document_versions, type: :uuid, on_delete: :restrict), null: false

      add :user_id, references(:users, type: :uuid, on_delete: :restrict), null: false
      add :person_id, references(:persons, type: :uuid, on_delete: :restrict)
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict)

      add :device_installation_id,
          references(:device_installations, type: :uuid, on_delete: :restrict)

      add :accepted_at, :timestamptz, null: false
      add :client_ip, :inet
      add :user_agent, :text
      add :evidence, :map, null: false, default: %{}
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:legal_acceptances, [:legal_document_version_id, :user_id])
    create index(:legal_acceptances, [:person_id, :accepted_at])
  end
end
