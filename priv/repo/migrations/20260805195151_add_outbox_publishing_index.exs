defmodule Clubeira.Repo.Migrations.AddOutboxPublishingIndex do
  use Ecto.Migration

  def up do
    create_if_not_exists index(:outbox_messages, [:locked_at, :id],
                           where: "status = 'publishing'",
                           name: :outbox_messages_publishing_idx
                         )
  end

  def down do
    drop_if_exists index(:outbox_messages, [:locked_at, :id],
                     where: "status = 'publishing'",
                     name: :outbox_messages_publishing_idx
                   )
  end
end
