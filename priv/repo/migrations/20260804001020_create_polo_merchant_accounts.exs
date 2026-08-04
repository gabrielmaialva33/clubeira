defmodule Clubeira.Repo.Migrations.CreatePoloMerchantAccounts do
  use Ecto.Migration

  def up do
    create table(:polo_merchant_accounts, primary_key: false) do
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict),
        primary_key: true,
        null: false

      add :payment_provider_id,
          references(:payment_providers, type: :uuid, on_delete: :restrict),
          null: false

      add :merchant_account_id,
          references(:merchant_accounts,
            type: :uuid,
            with: [payment_provider_id: :payment_provider_id],
            name: :polo_merchant_accounts_account_fkey,
            on_delete: :restrict
          ),
          primary_key: true,
          null: false

      add :role, :text, null: false, default: "primary"
      add :valid_during, :tstzrange, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:polo_merchant_accounts, [:merchant_account_id])

    create index(
             :polo_merchant_accounts,
             [:polo_id, :payment_provider_id, :role, :valid_during],
             name: :polo_merchant_accounts_active_lookup_idx
           )

    create constraint(:polo_merchant_accounts, :polo_merchant_accounts_role_check,
             check: "role IN ('primary', 'secondary')"
           )

    create constraint(:polo_merchant_accounts, :polo_merchant_accounts_valid_during_check,
             check:
               "NOT isempty(valid_during) AND NOT lower_inf(valid_during) AND lower_inc(valid_during) AND NOT upper_inc(valid_during)"
           )

    create constraint(:polo_merchant_accounts, :polo_merchant_accounts_one_primary,
             exclude:
               "gist (polo_id WITH =, payment_provider_id WITH =, valid_during WITH &&) WHERE (role = 'primary')"
           )

    execute("""
    ALTER TABLE payment_intents
    ADD CONSTRAINT payment_intents_polo_merchant_account_fkey
    FOREIGN KEY (polo_id, merchant_account_id)
    REFERENCES polo_merchant_accounts (polo_id, merchant_account_id)
    ON DELETE RESTRICT
    """)

    execute("""
    ALTER TABLE payment_provider_events
    ADD CONSTRAINT payment_provider_events_polo_merchant_account_fkey
    FOREIGN KEY (polo_id, merchant_account_id)
    REFERENCES polo_merchant_accounts (polo_id, merchant_account_id)
    MATCH SIMPLE
    ON DELETE RESTRICT
    """)

    execute("ALTER TABLE polo_merchant_accounts ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE polo_merchant_accounts FORCE ROW LEVEL SECURITY")

    execute("""
    CREATE POLICY polo_isolation ON polo_merchant_accounts
    FOR ALL
    USING (
      polo_id = NULLIF(current_setting('app.current_polo_id', true), '')::uuid
    )
    WITH CHECK (
      polo_id = NULLIF(current_setting('app.current_polo_id', true), '')::uuid
    )
    """)
  end

  def down do
    execute("""
    ALTER TABLE payment_provider_events
    DROP CONSTRAINT payment_provider_events_polo_merchant_account_fkey
    """)

    execute("""
    ALTER TABLE payment_intents
    DROP CONSTRAINT payment_intents_polo_merchant_account_fkey
    """)

    execute("DROP POLICY polo_isolation ON polo_merchant_accounts")
    execute("ALTER TABLE polo_merchant_accounts NO FORCE ROW LEVEL SECURITY")
    execute("ALTER TABLE polo_merchant_accounts DISABLE ROW LEVEL SECURITY")
    drop table(:polo_merchant_accounts)
  end
end
