defmodule Clubeira.Repo.Migrations.ScopeRedemptionAttemptIdempotencyToActor do
  use Ecto.Migration

  def up do
    drop index(:redemption_attempts, [:polo_id, :idempotency_key])

    create unique_index(
             :redemption_attempts,
             [:polo_id, :requesting_user_id, :idempotency_key],
             name: :redemption_attempts_actor_idempotency_uidx
           )
  end

  def down do
    drop index(:redemption_attempts, [:polo_id, :requesting_user_id, :idempotency_key],
           name: :redemption_attempts_actor_idempotency_uidx
         )

    create unique_index(:redemption_attempts, [:polo_id, :idempotency_key])
  end
end
