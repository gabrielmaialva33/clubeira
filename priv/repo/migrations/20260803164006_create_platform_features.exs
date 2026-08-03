defmodule Clubeira.Repo.Migrations.CreatePlatformFeatures do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:platform_features, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :key, :citext, null: false
      add :name, :text, null: false
      add :value_kind, :text, null: false
      add :status, :text, null: false, default: "active"

      timestamps(@timestamps_opts)
    end

    create unique_index(:platform_features, [:key])

    create constraint(:platform_features, :platform_features_value_kind_check,
             check: "value_kind IN ('boolean', 'integer')"
           )

    create constraint(:platform_features, :platform_features_status_check,
             check: "status IN ('active', 'retired')"
           )
  end
end
