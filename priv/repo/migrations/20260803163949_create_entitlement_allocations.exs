defmodule Clubeira.Repo.Migrations.CreateEntitlementAllocations do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:entitlement_allocations, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :cycle_entitlement_subject_id,
          references(:cycle_entitlement_subjects,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :entitlement_allocations_subject_fkey,
            on_delete: :restrict
          ),
          null: false

      add :benefit_package_item_id,
          references(:benefit_package_items,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :entitlement_allocations_package_item_fkey,
            on_delete: :restrict
          ),
          null: false

      add :entitlement_scope_id,
          references(:entitlement_scopes,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :entitlement_allocations_scope_fkey,
            on_delete: :restrict
          ),
          null: false

      add :polo_place_id,
          references(:polo_places,
            type: :uuid,
            with: [polo_id: :polo_id],
            match: :simple,
            name: :entitlement_allocations_polo_place_fkey,
            on_delete: :restrict
          )

      add :allocation_kind, :text, null: false
      add :issued_units, :integer, null: false
      add :available_units, :integer, null: false

      timestamps(@timestamps_opts)
    end

    create unique_index(:entitlement_allocations, [:id, :polo_id],
             name: :entitlement_allocations_id_polo_uidx
           )

    create unique_index(
             :entitlement_allocations,
             [:id, :polo_id, :benefit_package_item_id],
             name: :entitlement_allocations_item_identity_uidx
           )

    create unique_index(
             :entitlement_allocations,
             [
               :polo_id,
               :cycle_entitlement_subject_id,
               :benefit_package_item_id,
               :polo_place_id
             ],
             nulls_distinct: false,
             name: :entitlement_allocations_identity_uidx
           )

    create index(:entitlement_allocations, [:polo_id, :cycle_entitlement_subject_id],
             name: :entitlement_allocations_subject_idx
           )

    create constraint(:entitlement_allocations, :entitlement_allocations_kind_check,
             check:
               "(allocation_kind = 'per_place' AND polo_place_id IS NOT NULL) OR (allocation_kind = 'shared_scope' AND polo_place_id IS NULL)"
           )

    create constraint(:entitlement_allocations, :entitlement_allocations_units_check,
             check:
               "issued_units > 0 AND available_units >= 0 AND available_units <= issued_units"
           )
  end
end
