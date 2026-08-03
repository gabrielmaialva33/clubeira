defmodule Clubeira.Repo.Migrations.CreateRedemptions do
  use Ecto.Migration

  def change do
    create table(:redemptions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false
      add :polo_place_id, :uuid, null: false
      add :entitlement_allocation_id, :uuid, null: false

      add :redemption_attempt_id,
          references(:redemption_attempts,
            type: :uuid,
            with: [
              polo_id: :polo_id,
              entitlement_allocation_id: :entitlement_allocation_id,
              polo_place_id: :polo_place_id,
              benefit_package_item_id: :benefit_package_item_id,
              validation_point_id: :validation_point_id
            ],
            name: :redemptions_attempt_fkey,
            on_delete: :restrict
          ),
          null: false

      add :validation_point_id,
          references(:validation_points,
            type: :uuid,
            with: [polo_id: :polo_id, polo_place_id: :polo_place_id],
            name: :redemptions_validation_point_fkey,
            on_delete: :restrict
          ),
          null: false

      add :benefit_package_item_id,
          references(:benefit_package_items,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :redemptions_package_item_fkey,
            on_delete: :restrict
          ),
          null: false

      add :units, :integer, null: false, default: 1
      add :redeemed_at, :timestamptz, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:redemptions, [:id, :polo_id], name: :redemptions_id_polo_uidx)
    create unique_index(:redemptions, [:redemption_attempt_id])
    create index(:redemptions, [:polo_id, :polo_place_id, :redeemed_at])
    create index(:redemptions, [:polo_id, :entitlement_allocation_id, :redeemed_at])

    create constraint(:redemptions, :redemptions_units_check, check: "units > 0")
  end
end
