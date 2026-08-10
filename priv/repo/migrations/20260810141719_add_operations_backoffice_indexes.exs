defmodule Clubeira.Repo.Migrations.AddOperationsBackofficeIndexes do
  use Ecto.Migration

  def change do
    create index(:tenant_audit_events, [:polo_id, :occurred_at, :id],
             name: :tenant_audit_events_backoffice_feed_idx
           )

    create index(:tenant_audit_events, [:polo_id, :action, :occurred_at, :id],
             name: :tenant_audit_events_backoffice_action_feed_idx
           )

    create index(:tenant_audit_events, [:polo_id, :resource_type, :occurred_at, :id],
             name: :tenant_audit_events_backoffice_resource_feed_idx
           )

    create index(:outbox_messages, [:inserted_at, :id],
             name: :outbox_messages_backoffice_feed_idx
           )

    create index(:outbox_messages, [:status, :inserted_at, :id],
             name: :outbox_messages_backoffice_status_feed_idx
           )

    create index(:outbox_messages, [:topic, :inserted_at, :id],
             name: :outbox_messages_backoffice_topic_feed_idx
           )
  end
end
