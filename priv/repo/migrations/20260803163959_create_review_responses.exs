defmodule Clubeira.Repo.Migrations.CreateReviewResponses do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:review_responses, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :review_id, references(:reviews, type: :uuid, on_delete: :restrict), null: false

      add :organization_id, references(:organizations, type: :uuid, on_delete: :restrict),
        null: false

      add :author_user_id, references(:users, type: :uuid, on_delete: :restrict), null: false
      add :status, :text, null: false, default: "published"
      add :published_at, :timestamptz, null: false
      add :removed_at, :timestamptz

      timestamps(@timestamps_opts)
    end

    create unique_index(:review_responses, [:review_id, :organization_id])

    create constraint(:review_responses, :review_responses_status_check,
             check: "status IN ('published', 'hidden', 'removed')"
           )
  end
end
