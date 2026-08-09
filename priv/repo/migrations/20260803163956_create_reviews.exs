defmodule Clubeira.Repo.Migrations.CreateReviews do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:reviews, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :place_id, references(:places, type: :uuid, on_delete: :restrict), null: false
      add :author_user_id, references(:users, type: :uuid, on_delete: :restrict), null: false
      add :source_redemption_id, references(:redemptions, type: :uuid, on_delete: :restrict)
      add :verification_kind, :text, null: false
      add :status, :text, null: false, default: "pending"
      add :published_at, :timestamptz
      add :rejected_at, :timestamptz

      timestamps(@timestamps_opts)
    end

    create unique_index(:reviews, [:place_id, :author_user_id])

    create unique_index(:reviews, [:source_redemption_id],
             where: "source_redemption_id IS NOT NULL"
           )

    create index(:reviews, [:place_id, :status, :published_at])

    create index(:reviews, [:status, :inserted_at, :id], name: :reviews_moderation_queue_idx)

    create index(:reviews, [:place_id, :published_at, :id],
             where: "status = 'published'",
             name: :reviews_public_feed_idx
           )

    create constraint(:reviews, :reviews_verification_check,
             check:
               "(verification_kind = 'verified' AND source_redemption_id IS NOT NULL) OR (verification_kind = 'open' AND source_redemption_id IS NULL)"
           )

    create constraint(:reviews, :reviews_status_check,
             check: "status IN ('pending', 'published', 'hidden', 'rejected', 'removed')"
           )
  end
end
