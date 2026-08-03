defmodule Clubeira.Repo.Migrations.CreatePlatformPlanVersionFeatures do
  use Ecto.Migration

  def change do
    create table(:platform_plan_version_features, primary_key: false) do
      add :platform_plan_version_id,
          references(:platform_plan_versions, type: :uuid, on_delete: :restrict),
          primary_key: true,
          null: false

      add :platform_feature_id,
          references(:platform_features, type: :uuid, on_delete: :restrict),
          primary_key: true,
          null: false

      add :boolean_value, :boolean
      add :integer_value, :integer
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:platform_plan_version_features, [:platform_feature_id])

    create constraint(
             :platform_plan_version_features,
             :platform_plan_version_features_value_check,
             check: "(boolean_value IS NULL) <> (integer_value IS NULL)"
           )
  end
end
