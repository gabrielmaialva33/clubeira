defmodule Clubeira.Repo.Migrations.CreateModerationActions do
  use Ecto.Migration

  def change do
    create table(:moderation_actions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :review_id, references(:reviews, type: :uuid, on_delete: :restrict), null: false
      add :review_report_id, references(:review_reports, type: :uuid, on_delete: :restrict)
      add :actor_user_id, references(:users, type: :uuid, on_delete: :restrict), null: false
      add :action, :text, null: false
      add :reason, :text, null: false
      add :metadata, :map, null: false, default: %{}
      add :occurred_at, :timestamptz, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:moderation_actions, [:review_id, :occurred_at])
    create index(:moderation_actions, [:review_report_id])

    create constraint(:moderation_actions, :moderation_actions_action_check,
             check:
               "action IN ('publish', 'hide', 'reject', 'remove', 'restore', 'warn', 'close_report')"
           )
  end
end
