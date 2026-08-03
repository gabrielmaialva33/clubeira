defmodule Clubeira.Repo.Migrations.CreatePrivacyRequestEvents do
  use Ecto.Migration

  def change do
    create table(:privacy_request_events, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")

      add :privacy_request_id, references(:privacy_requests, type: :uuid, on_delete: :restrict),
        null: false

      add :actor_user_id, references(:users, type: :uuid, on_delete: :restrict)
      add :event_type, :text, null: false
      add :payload, :map, null: false, default: %{}
      add :occurred_at, :timestamptz, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:privacy_request_events, [:privacy_request_id, :occurred_at])
  end
end
