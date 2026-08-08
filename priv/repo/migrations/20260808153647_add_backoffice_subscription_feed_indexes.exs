defmodule Clubeira.Repo.Migrations.AddBackofficeSubscriptionFeedIndexes do
  use Ecto.Migration

  def change do
    create index(:access_contracts, [:polo_id, :inserted_at, :id],
             name: :access_contracts_backoffice_feed_idx
           )

    create index(:access_contracts, [:polo_id, :status, :inserted_at, :id],
             name: :access_contracts_backoffice_status_feed_idx
           )
  end
end
