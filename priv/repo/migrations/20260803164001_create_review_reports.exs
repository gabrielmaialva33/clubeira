defmodule Clubeira.Repo.Migrations.CreateReviewReports do
  use Ecto.Migration

  def change do
    create table(:review_reports, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :review_id, references(:reviews, type: :uuid, on_delete: :restrict), null: false
      add :reporter_user_id, references(:users, type: :uuid, on_delete: :restrict), null: false
      add :reason_code, :text, null: false
      add :details, :text
      add :status, :text, null: false, default: "open"
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:review_reports, [:review_id, :reporter_user_id],
             where: "status = 'open'",
             name: :review_reports_open_uidx
           )

    create index(:review_reports, [:status, :inserted_at, :id],
             name: :review_reports_status_keyset_idx
           )

    create constraint(:review_reports, :review_reports_status_check,
             check: "status IN ('open', 'accepted', 'rejected', 'closed')"
           )
  end
end
