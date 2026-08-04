defmodule Clubeira.Repo.Migrations.CreatePayments do
  use Ecto.Migration

  def change do
    create table(:payments, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :payment_intent_id,
          references(:payment_intents,
            type: :uuid,
            with: [polo_id: :polo_id, merchant_account_id: :merchant_account_id],
            name: :payments_intent_fkey,
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
      add :authorized_at, :timestamptz
      add :captured_at, :timestamptz
      add :failed_at, :timestamptz
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:payments, [:id, :polo_id], name: :payments_id_polo_uidx)

    create unique_index(:payments, [:merchant_account_id, :provider_reference],
             name: :payments_provider_reference_uidx
           )

    create index(:payments, [:polo_id, :payment_intent_id])

    create constraint(:payments, :payments_amount_check, check: "amount >= 0")

    create constraint(:payments, :payments_currency_check,
             check: "currency = upper(currency) AND char_length(currency) = 3"
           )

    create constraint(:payments, :payments_status_check,
             check: "status IN ('authorized', 'captured', 'failed', 'cancelled', 'refunded')"
           )
  end
end
