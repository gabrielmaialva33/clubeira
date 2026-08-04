defmodule Clubeira.Repo.Migrations.CreateOrderItems do
  use Ecto.Migration

  def change do
    create table(:order_items, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :order_id,
          references(:orders,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :order_items_order_fkey,
            on_delete: :restrict
          ),
          null: false

      add :product_offering_version_id,
          references(:product_offering_versions,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :order_items_offering_version_fkey,
            on_delete: :restrict
          ),
          null: false

      add :offering_price_id,
          references(:offering_prices,
            type: :uuid,
            with: [
              polo_id: :polo_id,
              product_offering_version_id: :product_offering_version_id
            ],
            name: :order_items_price_fkey,
            on_delete: :restrict
          ),
          null: false

      add :quantity, :smallint, null: false, default: 1
      add :unit_amount, :decimal, precision: 14, scale: 2, null: false
      add :total_amount, :decimal, precision: 14, scale: 2, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:order_items, [:id, :polo_id], name: :order_items_id_polo_uidx)

    create unique_index(:order_items, [:id, :polo_id, :product_offering_version_id],
             name: :order_items_offering_identity_uidx
           )

    create index(:order_items, [:polo_id, :order_id])

    create constraint(:order_items, :order_items_amounts_check,
             check: "quantity > 0 AND unit_amount >= 0 AND total_amount = quantity * unit_amount"
           )
  end
end
