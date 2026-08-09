defmodule Clubeira.Repo.Migrations.OperationalizeChargebacks do
  use Ecto.Migration

  def up do
    alter table(:chargebacks) do
      add :updated_at, :timestamptz, null: false, default: fragment("now()")
    end

    alter table(:payments) do
      add :charged_back_at, :timestamptz
    end

    drop constraint(:payments, :payments_status_check)
    drop constraint(:orders, :orders_status_check)
    drop constraint(:entitlement_ledger_entries, :entitlement_ledger_entries_kind_check)

    create constraint(:payments, :payments_status_check,
             check:
               "status IN ('authorized', 'captured', 'failed', 'cancelled', 'refunded', 'charged_back')"
           )

    create constraint(:payments, :payments_charged_back_at_check,
             check:
               "(status = 'charged_back' AND charged_back_at IS NOT NULL) OR (status <> 'charged_back' AND charged_back_at IS NULL)"
           )

    create constraint(:orders, :orders_status_check,
             check:
               "status IN ('pending', 'awaiting_payment', 'paid', 'cancelled', 'expired', 'refunded', 'charged_back')"
           )

    create constraint(:entitlement_ledger_entries, :entitlement_ledger_entries_kind_check,
             check:
               "(entry_kind = 'initial_grant' AND delta_units > 0 AND redemption_id IS NULL) OR " <>
                 "(entry_kind = 'consumption' AND delta_units < 0 AND redemption_id IS NOT NULL) OR " <>
                 "(entry_kind = 'manual_adjustment' AND redemption_id IS NULL) OR " <>
                 "(entry_kind IN ('refund_revocation', 'chargeback_revocation') AND delta_units < 0 AND redemption_id IS NULL)"
           )

    create constraint(:chargebacks, :chargebacks_closed_at_check,
             check:
               "(status IN ('open', 'under_review') AND closed_at IS NULL) OR (status IN ('won', 'lost', 'closed') AND closed_at IS NOT NULL)"
           )
  end

  def down do
    drop constraint(:chargebacks, :chargebacks_closed_at_check)
    drop constraint(:payments, :payments_charged_back_at_check)
    drop constraint(:payments, :payments_status_check)
    drop constraint(:orders, :orders_status_check)
    drop constraint(:entitlement_ledger_entries, :entitlement_ledger_entries_kind_check)

    create constraint(:payments, :payments_status_check,
             check: "status IN ('authorized', 'captured', 'failed', 'cancelled', 'refunded')"
           )

    create constraint(:orders, :orders_status_check,
             check:
               "status IN ('pending', 'awaiting_payment', 'paid', 'cancelled', 'expired', 'refunded')"
           )

    create constraint(:entitlement_ledger_entries, :entitlement_ledger_entries_kind_check,
             check:
               "(entry_kind = 'initial_grant' AND delta_units > 0 AND redemption_id IS NULL) OR " <>
                 "(entry_kind = 'consumption' AND delta_units < 0 AND redemption_id IS NOT NULL) OR " <>
                 "(entry_kind = 'manual_adjustment' AND redemption_id IS NULL) OR " <>
                 "(entry_kind = 'refund_revocation' AND delta_units < 0 AND redemption_id IS NULL)"
           )

    alter table(:payments) do
      remove :charged_back_at
    end

    alter table(:chargebacks) do
      remove :updated_at
    end
  end
end
