defmodule Clubeira.Repo.Migrations.AddBackofficePlaceFeedIndexes do
  use Ecto.Migration

  def change do
    create index(:polo_places, [:polo_id, :inserted_at, :id],
             name: :polo_places_backoffice_feed_idx
           )

    create index(:polo_places, [:polo_id, :status, :inserted_at, :id],
             name: :polo_places_backoffice_status_feed_idx
           )
  end
end
