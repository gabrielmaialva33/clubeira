defmodule Clubeira.Repo.Migrations.CreateProductOfferingPackageAssignments do
  use Ecto.Migration

  def change do
    create table(:product_offering_package_assignments, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :product_offering_version_id,
          references(:product_offering_versions,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :offering_package_assignments_offering_fkey,
            on_delete: :restrict
          ),
          null: false

      add :benefit_package_version_id,
          references(:benefit_package_versions,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :offering_package_assignments_package_fkey,
            on_delete: :restrict
          ),
          null: false

      add :valid_during, :tstzrange, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:product_offering_package_assignments, [:id, :polo_id],
             name: :offering_package_assignments_id_polo_uidx
           )

    create index(
             :product_offering_package_assignments,
             [:polo_id, :product_offering_version_id],
             name: :offering_package_assignments_lookup_idx
           )

    create constraint(
             :product_offering_package_assignments,
             :product_offering_package_assignments_valid_check,
             check:
               "NOT isempty(valid_during) AND NOT lower_inf(valid_during) AND lower_inc(valid_during) AND NOT upper_inc(valid_during)"
           )

    create constraint(
             :product_offering_package_assignments,
             :product_offering_package_assignments_no_overlap,
             exclude: "gist (product_offering_version_id WITH =, valid_during WITH &&)"
           )
  end
end
