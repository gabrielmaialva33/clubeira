defmodule Clubeira.Repo.Migrations.CreateChargebacks do
  use Ecto.Migration

  def change do
    create table(:chargebacks, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :payment_id,
          references(:payments,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :chargebacks_payment_fkey,
            on_delete: :restrict
          ),
          null: false

      add :provider_reference, :text, null: false
      add :amount, :decimal, precision: 14, scale: 2, null: false
      add :reason_code, :text
      add :status, :text, null: false
      add :opened_at, :timestamptz, null: false
      add :closed_at, :timestamptz
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:chargebacks, [:id, :polo_id], name: :chargebacks_id_polo_uidx)
    create unique_index(:chargebacks, [:payment_id, :provider_reference])

    create constraint(:chargebacks, :chargebacks_amount_check, check: "amount > 0")

    create constraint(:chargebacks, :chargebacks_status_check,
             check: "status IN ('open', 'under_review', 'won', 'lost', 'closed')"
           )
  end
end
