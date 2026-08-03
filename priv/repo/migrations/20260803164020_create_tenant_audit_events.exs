defmodule Clubeira.Repo.Migrations.CreateTenantAuditEvents do
  use Ecto.Migration

  def change do
    create table(:tenant_audit_events, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false
      add :actor_user_id, references(:users, type: :uuid, on_delete: :restrict)
      add :actor_kind, :text, null: false
      add :action, :text, null: false
      add :resource_type, :text, null: false
      add :resource_id, :uuid
      add :request_id, :uuid
      add :correlation_id, :uuid
      add :client_ip, :inet
      add :metadata, :map, null: false, default: %{}
      add :occurred_at, :timestamptz, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:tenant_audit_events, [:polo_id, :resource_type, :resource_id, :occurred_at],
             name: :tenant_audit_events_resource_idx
           )

    create index(:tenant_audit_events, [:polo_id, :actor_user_id, :occurred_at],
             name: :tenant_audit_events_actor_idx
           )

    create constraint(:tenant_audit_events, :tenant_audit_events_actor_kind_check,
             check: "actor_kind IN ('user', 'service', 'system')"
           )
  end
end
