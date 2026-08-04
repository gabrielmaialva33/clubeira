defmodule Clubeira.Repo.Migrations.CreateRedemptionAttempts do
  use Ecto.Migration

  def change do
    create table(:redemption_attempts, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false
      add :polo_place_id, :uuid, null: false

      add :validation_point_id,
          references(:validation_points,
            type: :uuid,
            with: [polo_id: :polo_id, polo_place_id: :polo_place_id],
            name: :redemption_attempts_validation_point_fkey,
            on_delete: :restrict
          ),
          null: false

      add :entitlement_allocation_id,
          references(:entitlement_allocations,
            type: :uuid,
            with: [polo_id: :polo_id, benefit_package_item_id: :benefit_package_item_id],
            name: :redemption_attempts_allocation_fkey,
            on_delete: :restrict
          ),
          null: false

      add :benefit_package_item_id,
          references(:benefit_package_items,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :redemption_attempts_package_item_fkey,
            on_delete: :restrict
          ),
          null: false

      add :requesting_user_id, references(:users, type: :uuid, on_delete: :restrict), null: false

      add :device_installation_id,
          references(:device_installations, type: :uuid, on_delete: :restrict),
          null: false

      add :operator_user_id, references(:users, type: :uuid, on_delete: :restrict)
      add :idempotency_key, :text, null: false
      add :decision, :text, null: false
      add :reason_code, :text
      add :request_nonce_hash, :binary, null: false
      add :client_ip, :inet
      add :risk_score, :decimal, precision: 5, scale: 4
      add :request_context, :map, null: false, default: %{}
      add :requested_at, :timestamptz, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:redemption_attempts, [:id, :polo_id],
             name: :redemption_attempts_id_polo_uidx
           )

    create unique_index(
             :redemption_attempts,
             [
               :id,
               :polo_id,
               :entitlement_allocation_id,
               :polo_place_id,
               :benefit_package_item_id,
               :validation_point_id
             ],
             name: :redemption_attempts_allocation_identity_uidx
           )

    create unique_index(
             :redemption_attempts,
             [:polo_id, :requesting_user_id, :idempotency_key],
             name: :redemption_attempts_actor_idempotency_uidx
           )

    create unique_index(:redemption_attempts, [:polo_id, :request_nonce_hash])
    create index(:redemption_attempts, [:polo_id, :polo_place_id, :requested_at])
    create index(:redemption_attempts, [:requesting_user_id, :requested_at])

    create constraint(:redemption_attempts, :redemption_attempts_decision_check,
             check: "decision IN ('accepted', 'denied', 'expired', 'cancelled')"
           )

    create constraint(:redemption_attempts, :redemption_attempts_risk_score_check,
             check: "risk_score IS NULL OR risk_score BETWEEN 0 AND 1"
           )
  end
end
