defmodule Clubeira.Repo.Migrations.CreatePlatformInvoices do
  use Ecto.Migration

  def change do
    create table(:platform_invoices, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :polo_platform_subscription_id,
          references(:polo_platform_subscriptions,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :platform_invoices_subscription_fkey,
            on_delete: :restrict
          ),
          null: false

      add :invoice_number, :citext, null: false
      add :billing_period, :tstzrange, null: false
      add :currency, :string, size: 3, null: false
      add :subtotal_amount, :decimal, precision: 14, scale: 2, null: false
      add :discount_amount, :decimal, precision: 14, scale: 2, null: false, default: 0
      add :total_amount, :decimal, precision: 14, scale: 2, null: false
      add :status, :text, null: false, default: "draft"
      add :issued_at, :timestamptz
      add :due_at, :timestamptz
      add :paid_at, :timestamptz
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:platform_invoices, [:id, :polo_id],
             name: :platform_invoices_id_polo_uidx
           )

    create unique_index(:platform_invoices, [:polo_id, :invoice_number])
    create index(:platform_invoices, [:polo_id, :status, :due_at])

    create constraint(:platform_invoices, :platform_invoices_amounts_check,
             check:
               "subtotal_amount >= 0 AND discount_amount >= 0 AND total_amount >= 0 AND total_amount = subtotal_amount - discount_amount"
           )

    create constraint(:platform_invoices, :platform_invoices_currency_check,
             check: "currency = upper(currency) AND char_length(currency) = 3"
           )

    create constraint(:platform_invoices, :platform_invoices_status_check,
             check: "status IN ('draft', 'open', 'paid', 'void', 'uncollectible')"
           )

    create constraint(:platform_invoices, :platform_invoices_period_check,
             check:
               "NOT isempty(billing_period) AND NOT lower_inf(billing_period) AND NOT upper_inf(billing_period) AND lower_inc(billing_period) AND NOT upper_inc(billing_period)"
           )
  end
end
