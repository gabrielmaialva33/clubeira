defmodule Clubeira.Repo.Migrations.CreateRefunds do
  use Ecto.Migration

  def change do
    create table(:refunds, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :payment_id,
          references(:payments,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :refunds_payment_fkey,
            on_delete: :restrict
          ),
          null: false

      add :provider_reference, :text, null: false
      add :amount, :decimal, precision: 14, scale: 2, null: false
      add :reason, :text, null: false
      add :status, :text, null: false, default: "requested"
      add :requested_at, :timestamptz, null: false
      add :completed_at, :timestamptz
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:refunds, [:id, :polo_id], name: :refunds_id_polo_uidx)
    create unique_index(:refunds, [:payment_id, :provider_reference])

    create constraint(:refunds, :refunds_amount_check, check: "amount > 0")

    create constraint(:refunds, :refunds_status_check,
             check: "status IN ('requested', 'processing', 'succeeded', 'failed', 'cancelled')"
           )
  end
end
