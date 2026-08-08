defmodule Clubeira.Repo.Migrations.StrengthenReviewReportModeration do
  use Ecto.Migration

  def up do
    drop_if_exists index(:review_reports, [:status, :inserted_at])

    create index(:review_reports, [:status, :inserted_at, :id],
             name: :review_reports_status_keyset_idx
           )

    drop_if_exists index(:moderation_actions, [:review_report_id])

    create unique_index(:moderation_actions, [:review_report_id],
             where: "review_report_id IS NOT NULL",
             name: :moderation_actions_review_report_uidx
           )
  end

  def down do
    drop_if_exists index(:moderation_actions, [:review_report_id],
                     name: :moderation_actions_review_report_uidx
                   )

    create index(:moderation_actions, [:review_report_id])

    drop_if_exists index(:review_reports, [:status, :inserted_at, :id],
                     name: :review_reports_status_keyset_idx
                   )

    create index(:review_reports, [:status, :inserted_at])
  end
end
