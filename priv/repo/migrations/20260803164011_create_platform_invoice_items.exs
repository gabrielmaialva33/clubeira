defmodule Clubeira.Repo.Migrations.CreatePlatformInvoiceItems do
  use Ecto.Migration

  def change do
    create table(:platform_invoice_items, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :platform_invoice_id,
          references(:platform_invoices,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :platform_invoice_items_invoice_fkey,
            on_delete: :restrict
          ),
          null: false

      add :item_kind, :text, null: false
      add :description, :text, null: false
      add :quantity, :integer, null: false, default: 1
      add :unit_amount, :decimal, precision: 14, scale: 2, null: false
      add :total_amount, :decimal, precision: 14, scale: 2, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:platform_invoice_items, [:polo_id, :platform_invoice_id])

    create constraint(:platform_invoice_items, :platform_invoice_items_kind_check,
             check: "item_kind IN ('plan', 'feature', 'adjustment', 'credit')"
           )

    create constraint(:platform_invoice_items, :platform_invoice_items_amounts_check,
             check: "quantity > 0 AND total_amount = quantity * unit_amount"
           )
  end
end
