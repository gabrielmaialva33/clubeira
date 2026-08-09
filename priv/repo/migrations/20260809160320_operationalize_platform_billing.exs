defmodule Clubeira.Repo.Migrations.OperationalizePlatformBilling do
  use Ecto.Migration

  def up do
    create unique_index(:platform_features, [:id, :value_kind],
             name: :platform_features_value_identity_uidx
           )

    alter table(:platform_plan_version_features) do
      add :value_kind, :text
    end

    execute("""
    UPDATE platform_plan_version_features AS assignment
    SET value_kind = feature.value_kind
    FROM platform_features AS feature
    WHERE feature.id = assignment.platform_feature_id
    """)

    alter table(:platform_plan_version_features) do
      modify :value_kind, :text, null: false
    end

    drop constraint(
           :platform_plan_version_features,
           :platform_plan_version_features_platform_feature_id_fkey
         )

    drop constraint(
           :platform_plan_version_features,
           :platform_plan_version_features_value_check
         )

    execute("""
    ALTER TABLE platform_plan_version_features
    ADD CONSTRAINT platform_plan_version_features_feature_fkey
    FOREIGN KEY (platform_feature_id, value_kind)
    REFERENCES platform_features (id, value_kind)
    ON DELETE RESTRICT
    """)

    create constraint(
             :platform_plan_version_features,
             :platform_plan_version_features_value_check,
             check:
               "(value_kind = 'boolean' AND boolean_value IS NOT NULL AND integer_value IS NULL) OR " <>
                 "(value_kind = 'integer' AND integer_value IS NOT NULL AND boolean_value IS NULL)"
           )

    create unique_index(:platform_prices, [:id, :platform_plan_version_id],
             name: :platform_prices_version_identity_uidx
           )

    alter table(:polo_platform_subscriptions) do
      add :requested_by_user_id, references(:users, type: :uuid, on_delete: :restrict)
      add :idempotency_key, :text
      add :request_sha256, :binary
      add :next_action, :map, null: false, default: %{}
      add :next_charge_at, :timestamptz
      modify :provider_reference, :text, null: true
    end

    drop constraint(
           :polo_platform_subscriptions,
           :polo_platform_subscriptions_platform_plan_version_id_fkey
         )

    drop constraint(
           :polo_platform_subscriptions,
           :polo_platform_subscriptions_platform_price_id_fkey
         )

    execute("""
    ALTER TABLE polo_platform_subscriptions
    ADD CONSTRAINT polo_platform_subscriptions_price_fkey
    FOREIGN KEY (platform_price_id, platform_plan_version_id)
    REFERENCES platform_prices (id, platform_plan_version_id)
    ON DELETE RESTRICT
    """)

    drop index(:polo_platform_subscriptions, [:polo_id, :platform_plan_version_id],
           name: :polo_platform_subscriptions_current_uidx
         )

    create unique_index(:polo_platform_subscriptions, [:polo_id],
             where: "status IN ('pending', 'active', 'past_due', 'suspended')",
             name: :polo_platform_subscriptions_current_uidx
           )

    create unique_index(
             :polo_platform_subscriptions,
             [:polo_id, :requested_by_user_id, :idempotency_key],
             where: "idempotency_key IS NOT NULL",
             name: :polo_platform_subscriptions_actor_idempotency_uidx
           )

    create unique_index(
             :polo_platform_subscriptions,
             [:id, :polo_id, :merchant_account_id],
             name: :polo_platform_subscriptions_merchant_identity_uidx
           )

    create constraint(
             :polo_platform_subscriptions,
             :polo_platform_subscriptions_reservation_check,
             check:
               "provider_reference IS NOT NULL OR (status = 'pending' AND idempotency_key IS NOT NULL AND request_sha256 IS NOT NULL AND requested_by_user_id IS NOT NULL)"
           )

    alter table(:platform_invoices) do
      add :merchant_account_id,
          references(:merchant_accounts, type: :uuid, on_delete: :restrict),
          null: false

      add :provider_reference, :text, null: false
    end

    drop constraint(:platform_invoices, :platform_invoices_subscription_fkey)

    execute("""
    ALTER TABLE platform_invoices
    ADD CONSTRAINT platform_invoices_subscription_fkey
    FOREIGN KEY (polo_platform_subscription_id, polo_id, merchant_account_id)
    REFERENCES polo_platform_subscriptions (id, polo_id, merchant_account_id)
    ON DELETE RESTRICT
    """)

    create unique_index(:platform_invoices, [:id, :polo_id, :merchant_account_id],
             name: :platform_invoices_merchant_identity_uidx
           )

    create unique_index(:platform_invoices, [:merchant_account_id, :provider_reference],
             name: :platform_invoices_provider_reference_uidx
           )

    drop constraint(:platform_payments, :platform_payments_invoice_fkey)

    execute("""
    ALTER TABLE platform_payments
    ADD CONSTRAINT platform_payments_invoice_fkey
    FOREIGN KEY (platform_invoice_id, polo_id, merchant_account_id)
    REFERENCES platform_invoices (id, polo_id, merchant_account_id)
    ON DELETE RESTRICT
    """)

    drop constraint(
           :payment_provider_events,
           :payment_provider_events_polo_merchant_account_fkey
         )

    execute("""
    CREATE FUNCTION enforce_payment_provider_event_account_scope()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
      account_kind text;
    BEGIN
      IF NEW.polo_id IS NULL THEN
        RETURN NEW;
      END IF;

      SELECT kind
      INTO account_kind
      FROM merchant_accounts
      WHERE id = NEW.merchant_account_id;

      IF account_kind = 'consumer' AND NOT EXISTS (
        SELECT 1
        FROM polo_merchant_accounts
        WHERE polo_id = NEW.polo_id
          AND merchant_account_id = NEW.merchant_account_id
      ) THEN
        RAISE EXCEPTION 'consumer merchant account is not linked to provider event polo'
          USING ERRCODE = '23503',
                CONSTRAINT = 'payment_provider_events_account_scope_check';
      ELSIF account_kind = 'platform' AND NOT EXISTS (
        SELECT 1
        FROM polo_platform_subscriptions
        WHERE polo_id = NEW.polo_id
          AND merchant_account_id = NEW.merchant_account_id
      ) THEN
        RAISE EXCEPTION 'platform merchant account has no subscription for provider event polo'
          USING ERRCODE = '23503',
                CONSTRAINT = 'payment_provider_events_account_scope_check';
      ELSIF account_kind NOT IN ('consumer', 'platform') THEN
        RAISE EXCEPTION 'merchant account kind is invalid for provider event'
          USING ERRCODE = '23503',
                CONSTRAINT = 'payment_provider_events_account_scope_check';
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER payment_provider_events_account_scope_check
    AFTER INSERT OR UPDATE OF polo_id, merchant_account_id
    ON payment_provider_events
    DEFERRABLE INITIALLY IMMEDIATE
    FOR EACH ROW
    EXECUTE FUNCTION enforce_payment_provider_event_account_scope()
    """)
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS payment_provider_events_account_scope_check ON payment_provider_events"
    )

    execute("DROP FUNCTION IF EXISTS enforce_payment_provider_event_account_scope()")

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'payment_provider_events_polo_merchant_account_fkey'
          AND conrelid = 'payment_provider_events'::regclass
      ) THEN
        ALTER TABLE payment_provider_events
        ADD CONSTRAINT payment_provider_events_polo_merchant_account_fkey
        FOREIGN KEY (polo_id, merchant_account_id)
        REFERENCES polo_merchant_accounts (polo_id, merchant_account_id)
        ON DELETE RESTRICT;
      END IF;
    END;
    $$
    """)

    execute("ALTER TABLE platform_payments DROP CONSTRAINT platform_payments_invoice_fkey")

    execute("""
    ALTER TABLE platform_payments
    ADD CONSTRAINT platform_payments_invoice_fkey
    FOREIGN KEY (platform_invoice_id, polo_id)
    REFERENCES platform_invoices (id, polo_id)
    ON DELETE RESTRICT
    """)

    drop index(:platform_invoices, [:merchant_account_id, :provider_reference],
           name: :platform_invoices_provider_reference_uidx
         )

    drop index(:platform_invoices, [:id, :polo_id, :merchant_account_id],
           name: :platform_invoices_merchant_identity_uidx
         )

    execute("ALTER TABLE platform_invoices DROP CONSTRAINT platform_invoices_subscription_fkey")

    execute("""
    ALTER TABLE platform_invoices
    ADD CONSTRAINT platform_invoices_subscription_fkey
    FOREIGN KEY (polo_platform_subscription_id, polo_id)
    REFERENCES polo_platform_subscriptions (id, polo_id)
    ON DELETE RESTRICT
    """)

    alter table(:platform_invoices) do
      remove :provider_reference
      remove :merchant_account_id
    end

    drop constraint(
           :polo_platform_subscriptions,
           :polo_platform_subscriptions_reservation_check
         )

    drop index(
           :polo_platform_subscriptions,
           [:id, :polo_id, :merchant_account_id],
           name: :polo_platform_subscriptions_merchant_identity_uidx
         )

    drop index(
           :polo_platform_subscriptions,
           [:polo_id, :requested_by_user_id, :idempotency_key],
           name: :polo_platform_subscriptions_actor_idempotency_uidx
         )

    drop index(:polo_platform_subscriptions, [:polo_id],
           name: :polo_platform_subscriptions_current_uidx
         )

    create unique_index(:polo_platform_subscriptions, [:polo_id, :platform_plan_version_id],
             where: "status IN ('pending', 'active', 'past_due', 'suspended')",
             name: :polo_platform_subscriptions_current_uidx
           )

    execute("""
    ALTER TABLE polo_platform_subscriptions
    DROP CONSTRAINT polo_platform_subscriptions_price_fkey
    """)

    alter table(:polo_platform_subscriptions) do
      modify :provider_reference, :text, null: false
      remove :next_charge_at
      remove :next_action
      remove :request_sha256
      remove :idempotency_key
      remove :requested_by_user_id
    end

    alter table(:polo_platform_subscriptions) do
      modify :platform_plan_version_id,
             references(:platform_plan_versions, type: :uuid, on_delete: :restrict),
             null: false

      modify :platform_price_id,
             references(:platform_prices, type: :uuid, on_delete: :restrict),
             null: false
    end

    drop index(:platform_prices, [:id, :platform_plan_version_id],
           name: :platform_prices_version_identity_uidx
         )

    execute("""
    ALTER TABLE platform_plan_version_features
    DROP CONSTRAINT platform_plan_version_features_feature_fkey
    """)

    drop constraint(
           :platform_plan_version_features,
           :platform_plan_version_features_value_check
         )

    create constraint(
             :platform_plan_version_features,
             :platform_plan_version_features_value_check,
             check: "(boolean_value IS NULL) <> (integer_value IS NULL)"
           )

    alter table(:platform_plan_version_features) do
      remove :value_kind
    end

    alter table(:platform_plan_version_features) do
      modify :platform_feature_id,
             references(:platform_features, type: :uuid, on_delete: :restrict),
             null: false
    end

    drop index(:platform_features, [:id, :value_kind],
           name: :platform_features_value_identity_uidx
         )
  end
end
