defmodule Clubeira.Repo.Migrations.CreateTenantIdempotencyKeys do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:tenant_idempotency_keys, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false
      add :user_id, references(:users, type: :uuid, on_delete: :restrict)
      add :scope, :text, null: false
      add :idempotency_key, :text, null: false
      add :request_sha256, :binary, null: false
      add :status, :text, null: false, default: "processing"
      add :response_status, :integer
      add :response_body, :map
      add :resource_type, :text
      add :resource_id, :uuid
      add :expires_at, :timestamptz, null: false

      timestamps(@timestamps_opts)
    end

    create unique_index(:tenant_idempotency_keys, [:polo_id, :scope, :idempotency_key],
             name: :tenant_idempotency_keys_scope_uidx
           )

    create index(:tenant_idempotency_keys, [:expires_at])

    create constraint(:tenant_idempotency_keys, :tenant_idempotency_keys_status_check,
             check: "status IN ('processing', 'completed', 'failed')"
           )

    create constraint(:tenant_idempotency_keys, :tenant_idempotency_keys_response_check,
             check:
               "(status = 'processing' AND response_status IS NULL) OR (status IN ('completed', 'failed') AND response_status IS NOT NULL)"
           )
  end
end
