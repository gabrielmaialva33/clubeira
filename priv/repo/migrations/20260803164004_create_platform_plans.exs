defmodule Clubeira.Repo.Migrations.CreatePlatformPlans do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:platform_plans, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :code, :citext, null: false
      add :name, :text, null: false
      add :status, :text, null: false, default: "draft"

      timestamps(@timestamps_opts)
    end

    create unique_index(:platform_plans, [:code])

    create constraint(:platform_plans, :platform_plans_status_check,
             check: "status IN ('draft', 'active', 'retired')"
           )
  end
end
