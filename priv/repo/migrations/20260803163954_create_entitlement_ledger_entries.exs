defmodule Clubeira.Repo.Migrations.CreateEntitlementLedgerEntries do
  use Ecto.Migration

  def change do
    create table(:entitlement_ledger_entries, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :entitlement_allocation_id,
          references(:entitlement_allocations,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :entitlement_ledger_entries_allocation_fkey,
            on_delete: :restrict
          ),
          null: false

      add :redemption_id,
          references(:redemptions,
            type: :uuid,
            with: [polo_id: :polo_id],
            match: :simple,
            name: :entitlement_ledger_entries_redemption_fkey,
            on_delete: :restrict
          )

      add :entry_kind, :text, null: false
      add :delta_units, :integer, null: false
      add :idempotency_key, :text, null: false
      add :occurred_at, :timestamptz, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:entitlement_ledger_entries, [:polo_id, :idempotency_key],
             name: :entitlement_ledger_entries_idempotency_uidx
           )

    create index(
             :entitlement_ledger_entries,
             [:polo_id, :entitlement_allocation_id, :occurred_at],
             name: :entitlement_ledger_entries_allocation_idx
           )

    create constraint(:entitlement_ledger_entries, :entitlement_ledger_entries_delta_check,
             check: "delta_units <> 0"
           )

    create constraint(:entitlement_ledger_entries, :entitlement_ledger_entries_kind_check,
             check:
               "(entry_kind = 'initial_grant' AND delta_units > 0 AND redemption_id IS NULL) OR " <>
                 "(entry_kind = 'consumption' AND delta_units < 0 AND redemption_id IS NOT NULL) OR " <>
                 "(entry_kind = 'manual_adjustment' AND redemption_id IS NULL) OR " <>
                 "(entry_kind = 'refund_revocation' AND delta_units < 0 AND redemption_id IS NULL)"
           )
  end
end
