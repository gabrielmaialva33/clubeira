defmodule Clubeira.Repo.Migrations.CreatePlatformPlanVersions do
  use Ecto.Migration

  def change do
    create table(:platform_plan_versions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")

      add :platform_plan_id,
          references(:platform_plans, type: :uuid, on_delete: :restrict),
          null: false

      add :version, :integer, null: false
      add :name, :text, null: false
      add :description, :text, null: false
      add :status, :text, null: false, default: "draft"
      add :published_at, :timestamptz
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:platform_plan_versions, [:platform_plan_id, :version])

    create constraint(:platform_plan_versions, :platform_plan_versions_version_check,
             check: "version > 0"
           )

    create constraint(:platform_plan_versions, :platform_plan_versions_status_check,
             check: "status IN ('draft', 'published', 'retired')"
           )
  end
end
