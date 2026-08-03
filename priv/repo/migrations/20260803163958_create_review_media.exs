defmodule Clubeira.Repo.Migrations.CreateReviewMedia do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:review_media, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")

      add :review_revision_id,
          references(:review_revisions, type: :uuid, on_delete: :restrict),
          null: false

      add :kind, :text, null: false
      add :storage_key, :text, null: false
      add :content_type, :text, null: false
      add :content_sha256, :binary, null: false
      add :position, :smallint, null: false
      add :width, :integer
      add :height, :integer
      add :duration_ms, :integer
      add :status, :text, null: false, default: "pending"

      timestamps(@timestamps_opts)
    end

    create unique_index(:review_media, [:storage_key])
    create unique_index(:review_media, [:review_revision_id, :position])

    create constraint(:review_media, :review_media_kind_check,
             check: "kind IN ('image', 'video')"
           )

    create constraint(:review_media, :review_media_position_check, check: "position >= 0")

    create constraint(:review_media, :review_media_dimensions_check,
             check:
               "(width IS NULL OR width > 0) AND (height IS NULL OR height > 0) AND (duration_ms IS NULL OR duration_ms > 0)"
           )

    create constraint(:review_media, :review_media_status_check,
             check: "status IN ('pending', 'ready', 'rejected', 'removed')"
           )
  end
end
