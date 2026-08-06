defmodule Clubeira.Repo.Migrations.AddBackofficeValidationPointFeedIndexes do
  use Ecto.Migration

  def change do
    create index(:validation_points, [:polo_id, :inserted_at, :id],
             name: :validation_points_backoffice_feed_idx
           )

    create index(:validation_points, [:polo_id, :status, :inserted_at, :id],
             name: :validation_points_backoffice_status_feed_idx
           )

    create index(:validation_points, [:polo_id, :polo_place_id, :inserted_at, :id],
             name: :validation_points_backoffice_place_feed_idx
           )
  end
end
