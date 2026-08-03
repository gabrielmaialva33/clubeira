defmodule Clubeira.Repo.Migrations.CreateRedemptionReversals do
  use Ecto.Migration

  def change do
    create table(:redemption_reversals, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :redemption_id,
          references(:redemptions,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :redemption_reversals_redemption_fkey,
            on_delete: :restrict
          ),
          null: false

      add :actor_user_id, references(:users, type: :uuid, on_delete: :restrict), null: false
      add :idempotency_key, :text, null: false
      add :reason_code, :text, null: false
      add :reason_detail, :text
      add :reversed_at, :timestamptz, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:redemption_reversals, [:id, :polo_id],
             name: :redemption_reversals_id_polo_uidx
           )

    create unique_index(:redemption_reversals, [:redemption_id])
    create unique_index(:redemption_reversals, [:polo_id, :idempotency_key])
  end
end
