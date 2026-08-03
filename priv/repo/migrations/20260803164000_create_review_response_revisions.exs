defmodule Clubeira.Repo.Migrations.CreateReviewResponseRevisions do
  use Ecto.Migration

  def change do
    create table(:review_response_revisions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")

      add :review_response_id,
          references(:review_responses, type: :uuid, on_delete: :restrict),
          null: false

      add :author_user_id, references(:users, type: :uuid, on_delete: :restrict), null: false
      add :revision_number, :integer, null: false
      add :body, :text, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:review_response_revisions, [:review_response_id, :revision_number],
             name: :review_response_revisions_number_uidx
           )

    create constraint(:review_response_revisions, :review_response_revisions_number_check,
             check: "revision_number > 0"
           )
  end
end
