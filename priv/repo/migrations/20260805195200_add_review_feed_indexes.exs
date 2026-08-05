defmodule Clubeira.Repo.Migrations.AddReviewFeedIndexes do
  use Ecto.Migration

  def up do
    create_if_not_exists index(:reviews, [:status, :inserted_at, :id],
                           name: :reviews_moderation_queue_idx
                         )

    create_if_not_exists index(:reviews, [:place_id, :published_at, :id],
                           where: "status = 'published'",
                           name: :reviews_public_feed_idx
                         )
  end

  def down do
    drop_if_exists index(:reviews, [:place_id, :published_at, :id],
                     where: "status = 'published'",
                     name: :reviews_public_feed_idx
                   )

    drop_if_exists index(:reviews, [:status, :inserted_at, :id],
                     name: :reviews_moderation_queue_idx
                   )
  end
end
