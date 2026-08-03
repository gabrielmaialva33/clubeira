defmodule Clubeira.Repo.Migrations.CreatePlatformPayments do
  use Ecto.Migration

  def change do
    create table(:platform_payments, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :platform_invoice_id,
          references(:platform_invoices,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :platform_payments_invoice_fkey,
            on_delete: :restrict
          ),
          null: false

      add :merchant_account_id,
          references(:merchant_accounts, type: :uuid, on_delete: :restrict),
          null: false

      add :provider_reference, :text, null: false
      add :currency, :string, size: 3, null: false
      add :amount, :decimal, precision: 14, scale: 2, null: false
      add :status, :text, null: false
      add :paid_at, :timestamptz
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:platform_payments, [:merchant_account_id, :provider_reference],
             name: :platform_payments_provider_reference_uidx
           )

    create index(:platform_payments, [:polo_id, :platform_invoice_id])

    create constraint(:platform_payments, :platform_payments_amount_check, check: "amount > 0")

    create constraint(:platform_payments, :platform_payments_currency_check,
             check: "currency = upper(currency) AND char_length(currency) = 3"
           )

    create constraint(:platform_payments, :platform_payments_status_check,
             check: "status IN ('pending', 'succeeded', 'failed', 'refunded')"
           )
  end
end
