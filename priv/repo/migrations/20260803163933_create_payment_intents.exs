defmodule Clubeira.Repo.Migrations.CreatePaymentIntents do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:payment_intents, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :order_id,
          references(:orders,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :payment_intents_order_fkey,
            on_delete: :restrict
          ),
          null: false

      add :merchant_account_id,
          references(:merchant_accounts, type: :uuid, on_delete: :restrict),
          null: false

      add :idempotency_key, :text, null: false
      add :provider_reference, :text
      add :currency, :string, size: 3, null: false
      add :amount, :decimal, precision: 14, scale: 2, null: false
      add :status, :text, null: false, default: "created"
      add :expires_at, :timestamptz

      timestamps(@timestamps_opts)
    end

    create unique_index(:payment_intents, [:id, :polo_id], name: :payment_intents_id_polo_uidx)

    create unique_index(:payment_intents, [:polo_id, :idempotency_key])

    create unique_index(:payment_intents, [:merchant_account_id, :provider_reference],
             where: "provider_reference IS NOT NULL",
             name: :payment_intents_provider_reference_uidx
           )

    create index(:payment_intents, [:polo_id, :order_id])

    create constraint(:payment_intents, :payment_intents_amount_check, check: "amount >= 0")

    create constraint(:payment_intents, :payment_intents_currency_check,
             check: "currency = upper(currency) AND char_length(currency) = 3"
           )

    create constraint(:payment_intents, :payment_intents_status_check,
             check:
               "status IN ('created', 'requires_action', 'processing', 'authorized', 'succeeded', 'failed', 'cancelled', 'expired')"
           )
  end
end
