defmodule Clubeira.Repo.Migrations.SupportFullPaymentRefunds do
  use Ecto.Migration

  def up do
    alter table(:payments) do
      add :refunded_at, :timestamptz
    end

    create constraint(:payments, :payments_refunded_at_check,
             check: "status <> 'refunded' OR refunded_at IS NOT NULL"
           )

    drop unique_index(:refunds, [:payment_id, :provider_reference],
           name: :refunds_payment_id_provider_reference_index
         )

    alter table(:refunds) do
      modify :provider_reference, :text, null: true

      add :requested_by_user_id,
          references(:users, type: :uuid, on_delete: :restrict)

      add :idempotency_key, :text
      add :request_sha256, :binary
      add :failure_reason, :text
      add :updated_at, :timestamptz, null: false, default: fragment("now()")
    end

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

    drop constraint(:entitlement_ledger_entries, :entitlement_ledger_entries_kind_check)

    create constraint(:entitlement_ledger_entries, :entitlement_ledger_entries_kind_check,
             check:
               "(entry_kind = 'initial_grant' AND delta_units > 0 AND redemption_id IS NULL) OR " <>
                 "(entry_kind = 'consumption' AND delta_units < 0 AND redemption_id IS NOT NULL) OR " <>
                 "(entry_kind = 'manual_adjustment' AND redemption_id IS NULL) OR " <>
                 "(entry_kind = 'refund_revocation' AND delta_units < 0 AND redemption_id IS NULL)"
           )
  end

  def down do
    drop constraint(:entitlement_ledger_entries, :entitlement_ledger_entries_kind_check)

    create constraint(:entitlement_ledger_entries, :entitlement_ledger_entries_kind_check,
             check:
               "(entry_kind = 'initial_grant' AND delta_units > 0 AND redemption_id IS NULL) OR " <>
                 "(entry_kind = 'consumption' AND delta_units < 0 AND redemption_id IS NOT NULL) OR " <>
                 "(entry_kind = 'manual_adjustment' AND redemption_id IS NULL)"
           )

    drop constraint(:refunds, :refunds_resolution_check)
    drop constraint(:refunds, :refunds_reason_check)
    drop constraint(:refunds, :refunds_provider_reference_check)
    drop constraint(:refunds, :refunds_idempotency_key_check)
    drop constraint(:refunds, :refunds_request_identity_check)

    drop unique_index(:refunds, [:polo_id, :payment_id], name: :refunds_succeeded_payment_uidx)

    drop unique_index(:refunds, [:polo_id, :payment_id], name: :refunds_live_payment_uidx)

    drop unique_index(:refunds, [:polo_id, :requested_by_user_id, :idempotency_key],
           name: :refunds_actor_idempotency_uidx
         )

    drop unique_index(:refunds, [:payment_id, :provider_reference],
           name: :refunds_payment_provider_reference_uidx
         )

    execute(
      "UPDATE refunds SET provider_reference = 'local:' || id::text WHERE provider_reference IS NULL"
    )

    alter table(:refunds) do
      modify :provider_reference, :text, null: false
      remove :updated_at
      remove :failure_reason
      remove :request_sha256
      remove :idempotency_key
      remove :requested_by_user_id
    end

    create unique_index(:refunds, [:payment_id, :provider_reference],
             name: :refunds_payment_id_provider_reference_index
           )

    execute("ALTER TABLE payments DROP CONSTRAINT IF EXISTS payments_refunded_at_check")
    execute("ALTER TABLE payments DROP COLUMN IF EXISTS refunded_at")
  end
end
