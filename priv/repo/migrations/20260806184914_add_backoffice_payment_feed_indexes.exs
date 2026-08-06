defmodule Clubeira.Repo.Migrations.AddBackofficePaymentFeedIndexes do
  use Ecto.Migration

  def up do
    create_if_not_exists index(:payments, [:polo_id, :inserted_at, :id],
                           name: :payments_backoffice_feed_idx
                         )

    create_if_not_exists index(:payments, [:polo_id, :status, :inserted_at, :id],
                           name: :payments_backoffice_status_feed_idx
                         )

    create_if_not_exists index(:refunds, [:polo_id, :payment_id, :inserted_at, :id],
                           name: :refunds_backoffice_payment_feed_idx
                         )
  end

  def down do
    drop_if_exists index(:refunds, [:polo_id, :payment_id, :inserted_at, :id],
                     name: :refunds_backoffice_payment_feed_idx
                   )

    drop_if_exists index(:payments, [:polo_id, :status, :inserted_at, :id],
                     name: :payments_backoffice_status_feed_idx
                   )

    drop_if_exists index(:payments, [:polo_id, :inserted_at, :id],
                     name: :payments_backoffice_feed_idx
                   )
  end
end
