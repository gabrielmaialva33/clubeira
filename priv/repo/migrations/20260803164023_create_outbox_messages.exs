defmodule Clubeira.Repo.Migrations.CreateOutboxMessages do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:outbox_messages, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")

      add :domain_event_id, references(:domain_events, type: :uuid, on_delete: :restrict),
        null: false

      add :topic, :text, null: false
      add :message_key, :text, null: false
      add :payload, :map, null: false
      add :status, :text, null: false, default: "pending"
      add :attempt_count, :integer, null: false, default: 0
      add :available_at, :timestamptz, null: false, default: fragment("now()")
      add :locked_at, :timestamptz
      add :locked_by, :text
      add :published_at, :timestamptz
      add :last_error, :text

      timestamps(@timestamps_opts)
    end

    create unique_index(:outbox_messages, [:domain_event_id])

    create index(:outbox_messages, [:available_at, :id],
             where: "status = 'pending'",
             name: :outbox_messages_pending_idx
           )

    create constraint(:outbox_messages, :outbox_messages_status_check,
             check: "status IN ('pending', 'publishing', 'published', 'dead_letter')"
           )

    create constraint(:outbox_messages, :outbox_messages_attempt_count_check,
             check: "attempt_count >= 0"
           )
  end
end
