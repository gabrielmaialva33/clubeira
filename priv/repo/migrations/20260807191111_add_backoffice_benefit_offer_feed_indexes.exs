defmodule Clubeira.Repo.Migrations.AddBackofficeBenefitOfferFeedIndexes do
  use Ecto.Migration

  def change do
    create index(:benefit_offers, [:polo_id, :inserted_at, :id],
             name: :benefit_offers_backoffice_feed_idx
           )

    create index(:benefit_offers, [:polo_id, :status, :inserted_at, :id],
             name: :benefit_offers_backoffice_status_feed_idx
           )
  end
end
