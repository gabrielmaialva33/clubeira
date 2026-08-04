defmodule Clubeira.Repo.Migrations.CreateSystemAuditEvents do
  use Ecto.Migration

  def change do
    create table(:system_audit_events, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :actor_user_id, references(:users, type: :uuid, on_delete: :restrict)
      add :actor_kind, :text, null: false
      add :action, :text, null: false
      add :resource_type, :text, null: false
      add :resource_id, :uuid
      add :request_id, :uuid
      add :correlation_id, :uuid
      add :metadata, :map, null: false, default: %{}
      add :occurred_at, :timestamptz, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:system_audit_events, [:resource_type, :resource_id, :occurred_at],
             name: :system_audit_events_resource_idx
           )

    create constraint(:system_audit_events, :system_audit_events_actor_kind_check,
             check: "actor_kind IN ('user', 'service', 'system')"
           )
  end
end
