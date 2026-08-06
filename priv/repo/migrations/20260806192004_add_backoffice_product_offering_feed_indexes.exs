defmodule Clubeira.Repo.Migrations.AddBackofficeProductOfferingFeedIndexes do
  use Ecto.Migration

  def change do
    create index(:product_offerings, [:polo_id, :inserted_at, :id],
             name: :product_offerings_backoffice_feed_idx
           )

    create index(:product_offerings, [:polo_id, :status, :inserted_at, :id],
             name: :product_offerings_backoffice_status_feed_idx
           )
  end
end
