defmodule Clubeira.Repo.Migrations.CreateBenefitPackageItems do
  use Ecto.Migration

  def change do
    create table(:benefit_package_items, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :benefit_package_version_id,
          references(:benefit_package_versions,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :benefit_package_items_package_version_fkey,
            on_delete: :restrict
          ),
          null: false

      add :benefit_offer_version_id,
          references(:benefit_offer_versions,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :benefit_package_items_offer_version_fkey,
            on_delete: :restrict
          ),
          null: false

      add :entitlement_scope_id,
          references(:entitlement_scopes,
            type: :uuid,
            with: [
              polo_id: :polo_id,
              benefit_package_version_id: :benefit_package_version_id
            ],
            name: :benefit_package_items_scope_fkey,
            on_delete: :restrict
          ),
          null: false

      add :allowance_per_cycle, :smallint, null: false, default: 1
      add :consumption_unit, :text, null: false
      add :subject_policy, :text, null: false
      add :stacking_policy, :text, null: false, default: "exclusive"
      add :priority, :smallint, null: false, default: 100
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:benefit_package_items, [:id, :polo_id],
             name: :benefit_package_items_id_polo_uidx
           )

    create unique_index(
             :benefit_package_items,
             [:id, :polo_id, :entitlement_scope_id, :consumption_unit],
             name: :benefit_package_items_allocation_identity_uidx
           )

    create unique_index(
             :benefit_package_items,
             [
               :polo_id,
               :benefit_package_version_id,
               :benefit_offer_version_id,
               :entitlement_scope_id
             ],
             name: :benefit_package_items_definition_uidx
           )

    create constraint(:benefit_package_items, :benefit_package_items_allowance_check,
             check: "allowance_per_cycle > 0"
           )

    create constraint(:benefit_package_items, :benefit_package_items_consumption_check,
             check: "consumption_unit IN ('per_place', 'shared_scope')"
           )

    create constraint(:benefit_package_items, :benefit_package_items_subject_check,
             check: "subject_policy IN ('per_beneficiary', 'shared_contract')"
           )

    create constraint(:benefit_package_items, :benefit_package_items_stacking_check,
             check: "stacking_policy IN ('exclusive', 'stackable', 'priority')"
           )
  end
end
