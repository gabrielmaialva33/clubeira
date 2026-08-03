defmodule Clubeira.Repo.Migrations.CreateBenefitPackageVersions do
  use Ecto.Migration

  def change do
    create table(:benefit_package_versions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :benefit_package_id,
          references(:benefit_packages,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :benefit_package_versions_package_fkey,
            on_delete: :restrict
          ),
          null: false

      add :version, :integer, null: false
      add :name, :text, null: false
      add :status, :text, null: false, default: "draft"
      add :published_at, :timestamptz
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(
             :benefit_package_versions,
             [:polo_id, :benefit_package_id, :version],
             name: :benefit_package_versions_number_uidx
           )

    create unique_index(:benefit_package_versions, [:id, :polo_id],
             name: :benefit_package_versions_id_polo_uidx
           )

    create constraint(:benefit_package_versions, :benefit_package_versions_version_check,
             check: "version > 0"
           )

    create constraint(:benefit_package_versions, :benefit_package_versions_status_check,
             check: "status IN ('draft', 'published', 'retired')"
           )
  end
end
