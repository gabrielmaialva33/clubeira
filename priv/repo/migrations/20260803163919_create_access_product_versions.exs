defmodule Clubeira.Repo.Migrations.CreateAccessProductVersions do
  use Ecto.Migration

  def change do
    create table(:access_product_versions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :access_product_id,
          references(:access_products,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :access_product_versions_product_fkey,
            on_delete: :restrict
          ),
          null: false

      add :version, :integer, null: false
      add :name, :text, null: false
      add :description, :text, null: false
      add :status, :text, null: false, default: "draft"
      add :published_at, :timestamptz
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:access_product_versions, [:polo_id, :access_product_id, :version],
             name: :access_product_versions_number_uidx
           )

    create unique_index(:access_product_versions, [:id, :polo_id],
             name: :access_product_versions_id_polo_uidx
           )

    create constraint(:access_product_versions, :access_product_versions_version_check,
             check: "version > 0"
           )

    create constraint(:access_product_versions, :access_product_versions_status_check,
             check: "status IN ('draft', 'published', 'retired')"
           )
  end
end
