defmodule Clubeira.Repo.Migrations.ScopeTenantIdempotencyKeysToActor do
  use Ecto.Migration

  def up do
    drop index(:tenant_idempotency_keys, [:polo_id, :scope, :idempotency_key],
           name: :tenant_idempotency_keys_scope_uidx
         )

    create unique_index(
             :tenant_idempotency_keys,
             [:polo_id, :user_id, :scope, :idempotency_key],
             nulls_distinct: false,
             name: :tenant_idempotency_keys_scope_uidx
           )
  end

  def down do
    drop index(:tenant_idempotency_keys, [:polo_id, :user_id, :scope, :idempotency_key],
           name: :tenant_idempotency_keys_scope_uidx
         )

    create unique_index(:tenant_idempotency_keys, [:polo_id, :scope, :idempotency_key],
             name: :tenant_idempotency_keys_scope_uidx
           )
  end
end
