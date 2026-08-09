defmodule Clubeira.Repo.Migrations.OperationalizeConsumerRecurringBilling do
  use Ecto.Migration

  def up do
    drop_if_exists index(:billing_agreements, [:merchant_account_id, :provider_reference],
                     name: :billing_agreements_provider_reference_uidx
                   )

    execute("ALTER TABLE billing_agreements ALTER COLUMN provider_reference DROP NOT NULL")

    alter table(:billing_agreements) do
      add :order_item_id, :uuid
      add :idempotency_key, :text
      add :request_sha256, :binary
      add :next_action, :map, null: false, default: %{}
    end

    execute("""
    ALTER TABLE billing_agreements
    ADD CONSTRAINT billing_agreements_order_item_fkey
    FOREIGN KEY (order_item_id, polo_id, product_offering_version_id)
    REFERENCES order_items (id, polo_id, product_offering_version_id)
    ON DELETE RESTRICT
    """)

    execute("""
    ALTER TABLE billing_agreements
    ADD CONSTRAINT billing_agreements_polo_merchant_account_fkey
    FOREIGN KEY (polo_id, merchant_account_id)
    REFERENCES polo_merchant_accounts (polo_id, merchant_account_id)
    ON DELETE RESTRICT
    """)

    create unique_index(:billing_agreements, [:merchant_account_id, :provider_reference],
             name: :billing_agreements_provider_reference_uidx,
             where: "provider_reference IS NOT NULL"
           )

    create unique_index(:billing_agreements, [:polo_id, :order_item_id],
             name: :billing_agreements_order_item_uidx,
             where: "order_item_id IS NOT NULL"
           )

    create unique_index(:billing_agreements, [:polo_id, :user_id, :idempotency_key],
             name: :billing_agreements_actor_idempotency_uidx,
             where: "idempotency_key IS NOT NULL"
           )

    create constraint(:billing_agreements, :billing_agreements_reservation_check,
             check:
               "(order_item_id IS NULL AND idempotency_key IS NULL AND request_sha256 IS NULL) OR " <>
                 "(order_item_id IS NOT NULL AND idempotency_key IS NOT NULL AND request_sha256 IS NOT NULL)"
           )

    alter table(:consumer_invoices) do
      add :merchant_account_id, :uuid
      add :provider_reference, :text
    end

    execute("""
    ALTER TABLE consumer_invoices
    ADD CONSTRAINT consumer_invoices_polo_merchant_account_fkey
    FOREIGN KEY (polo_id, merchant_account_id)
    REFERENCES polo_merchant_accounts (polo_id, merchant_account_id)
    ON DELETE RESTRICT
    """)

    create unique_index(:consumer_invoices, [:merchant_account_id, :provider_reference],
             name: :consumer_invoices_provider_reference_uidx,
             where: "provider_reference IS NOT NULL"
           )

    create constraint(:consumer_invoices, :consumer_invoices_provider_identity_check,
             check:
               "(merchant_account_id IS NULL AND provider_reference IS NULL) OR " <>
                 "(merchant_account_id IS NOT NULL AND provider_reference IS NOT NULL)"
           )
  end

  def down do
    drop constraint(:consumer_invoices, :consumer_invoices_provider_identity_check)

    drop index(:consumer_invoices, [:merchant_account_id, :provider_reference],
           name: :consumer_invoices_provider_reference_uidx
         )

    execute("""
    ALTER TABLE consumer_invoices
    DROP CONSTRAINT consumer_invoices_polo_merchant_account_fkey
    """)

    alter table(:consumer_invoices) do
      remove :provider_reference
      remove :merchant_account_id
    end

    drop constraint(:billing_agreements, :billing_agreements_reservation_check)

    drop index(:billing_agreements, [:polo_id, :user_id, :idempotency_key],
           name: :billing_agreements_actor_idempotency_uidx
         )

    drop index(:billing_agreements, [:polo_id, :order_item_id],
           name: :billing_agreements_order_item_uidx
         )

    drop index(:billing_agreements, [:merchant_account_id, :provider_reference],
           name: :billing_agreements_provider_reference_uidx
         )

    execute("""
    ALTER TABLE billing_agreements
    DROP CONSTRAINT billing_agreements_polo_merchant_account_fkey
    """)

    execute("""
    ALTER TABLE billing_agreements
    DROP CONSTRAINT billing_agreements_order_item_fkey
    """)

    alter table(:billing_agreements) do
      remove :next_action
      remove :request_sha256
      remove :idempotency_key
      remove :order_item_id
    end

    execute("ALTER TABLE billing_agreements ALTER COLUMN provider_reference SET NOT NULL")

    create unique_index(:billing_agreements, [:merchant_account_id, :provider_reference],
             name: :billing_agreements_provider_reference_uidx
           )
  end
end
