defmodule Clubeira.Repo.Migrations.CreateConsumerInvoices do
  use Ecto.Migration

  def change do
    create table(:consumer_invoices, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :billing_agreement_id,
          references(:billing_agreements,
            type: :uuid,
            with: [polo_id: :polo_id],
            match: :simple,
            name: :consumer_invoices_billing_agreement_fkey,
            on_delete: :restrict
          )

      add :order_id,
          references(:orders,
            type: :uuid,
            with: [polo_id: :polo_id],
            match: :simple,
            name: :consumer_invoices_order_fkey,
            on_delete: :restrict
          )

      add :invoice_number, :citext, null: false
      add :billing_period, :tstzrange
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

    create unique_index(:consumer_invoices, [:id, :polo_id],
             name: :consumer_invoices_id_polo_uidx
           )

    create unique_index(:consumer_invoices, [:polo_id, :invoice_number])
    create index(:consumer_invoices, [:billing_agreement_id, :issued_at])

    create constraint(:consumer_invoices, :consumer_invoices_source_check,
             check: "billing_agreement_id IS NOT NULL OR order_id IS NOT NULL"
           )

    create constraint(:consumer_invoices, :consumer_invoices_amounts_check,
             check:
               "subtotal_amount >= 0 AND discount_amount >= 0 AND total_amount >= 0 AND total_amount = subtotal_amount - discount_amount"
           )

    create constraint(:consumer_invoices, :consumer_invoices_currency_check,
             check: "currency = upper(currency) AND char_length(currency) = 3"
           )

    create constraint(:consumer_invoices, :consumer_invoices_status_check,
             check: "status IN ('draft', 'open', 'paid', 'void', 'uncollectible', 'refunded')"
           )

    create constraint(:consumer_invoices, :consumer_invoices_period_check,
             check:
               "billing_period IS NULL OR (NOT isempty(billing_period) AND NOT lower_inf(billing_period) AND NOT upper_inf(billing_period) AND lower_inc(billing_period) AND NOT upper_inc(billing_period))"
           )
  end
end
