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

      add :provider_reference, :text
      add :requested_by_user_id, references(:users, type: :uuid, on_delete: :restrict)
      add :idempotency_key, :text
      add :request_sha256, :binary
      add :amount, :decimal, precision: 14, scale: 2, null: false
      add :reason, :text, null: false
      add :status, :text, null: false, default: "requested"
      add :requested_at, :timestamptz, null: false
      add :completed_at, :timestamptz
      add :failure_reason, :text
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
      add :updated_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:refunds, [:id, :polo_id], name: :refunds_id_polo_uidx)

    create unique_index(:refunds, [:payment_id, :provider_reference],
             where: "provider_reference IS NOT NULL",
             name: :refunds_payment_provider_reference_uidx
           )

    create unique_index(
             :refunds,
             [:polo_id, :requested_by_user_id, :idempotency_key],
             where: "idempotency_key IS NOT NULL",
             name: :refunds_actor_idempotency_uidx
           )

    create unique_index(:refunds, [:polo_id, :payment_id],
             where: "status IN ('requested', 'processing')",
             name: :refunds_live_payment_uidx
           )

    create unique_index(:refunds, [:polo_id, :payment_id],
             where: "status = 'succeeded'",
             name: :refunds_succeeded_payment_uidx
           )

    create index(:refunds, [:polo_id, :payment_id, :inserted_at, :id],
             name: :refunds_backoffice_payment_feed_idx
           )

    create constraint(:refunds, :refunds_amount_check, check: "amount > 0")

    create constraint(:refunds, :refunds_status_check,
             check: "status IN ('requested', 'processing', 'succeeded', 'failed', 'cancelled')"
           )

    create constraint(:refunds, :refunds_request_identity_check,
             check:
               "(requested_by_user_id IS NULL AND idempotency_key IS NULL AND request_sha256 IS NULL) OR " <>
                 "(requested_by_user_id IS NOT NULL AND idempotency_key IS NOT NULL AND request_sha256 IS NOT NULL)"
           )

    create constraint(:refunds, :refunds_idempotency_key_check,
             check:
               "idempotency_key IS NULL OR (octet_length(idempotency_key) BETWEEN 8 AND 128 AND idempotency_key ~ '^[A-Za-z0-9._:-]+$')"
           )

    create constraint(:refunds, :refunds_provider_reference_check,
             check:
               "provider_reference IS NULL OR octet_length(provider_reference) BETWEEN 1 AND 255"
           )

    create constraint(:refunds, :refunds_reason_check,
             check: "char_length(btrim(reason)) BETWEEN 3 AND 500"
           )

    create constraint(:refunds, :refunds_resolution_check,
             check:
               "(status IN ('requested', 'processing') AND completed_at IS NULL AND failure_reason IS NULL) OR " <>
                 "(status = 'succeeded' AND completed_at IS NOT NULL AND provider_reference IS NOT NULL AND failure_reason IS NULL) OR " <>
                 "(status IN ('failed', 'cancelled') AND completed_at IS NOT NULL AND failure_reason IS NOT NULL)"
           )
  end
end
