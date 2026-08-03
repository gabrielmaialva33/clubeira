defmodule Clubeira.Repo.Migrations.CreateReviewRevisions do
  use Ecto.Migration

  def change do
    create table(:review_revisions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :review_id, references(:reviews, type: :uuid, on_delete: :restrict), null: false
      add :author_user_id, references(:users, type: :uuid, on_delete: :restrict), null: false
      add :revision_number, :integer, null: false
      add :rating, :smallint, null: false
      add :title, :text
      add :body, :text, null: false
      add :edit_reason, :text
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:review_revisions, [:review_id, :revision_number])

    create constraint(:review_revisions, :review_revisions_number_check,
             check: "revision_number > 0"
           )

    create constraint(:review_revisions, :review_revisions_rating_check,
             check: "rating BETWEEN 1 AND 5"
           )
  end
end
