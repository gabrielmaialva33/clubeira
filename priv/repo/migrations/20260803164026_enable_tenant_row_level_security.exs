defmodule Clubeira.Repo.Migrations.EnableTenantRowLevelSecurity do
  use Ecto.Migration

  # Rows whose polo_id is NULL are platform records. This tenant policy hides
  # them by default; system workers need their own restricted role and policy.
  @tenant_tables ~w(
    polo_policy_versions
    polo_roles
    polo_memberships
    polo_membership_roles
    polo_places
    partner_agreement_polos
    partner_agreement_polo_places
    editions
    edition_places
    partner_agreement_editions
    benefit_offers
    benefit_offer_versions
    benefit_offer_version_places
    benefit_offer_availability_windows
    benefit_offer_blackout_periods
    partner_agreement_offer_versions
    access_products
    access_product_versions
    product_offerings
    product_offering_versions
    offering_prices
    benefit_packages
    benefit_package_versions
    entitlement_scopes
    entitlement_scope_places
    benefit_package_items
    product_offering_package_assignments
    orders
    order_items
    payment_intents
    payments
    refunds
    chargebacks
    billing_agreements
    consumer_invoices
    access_contracts
    contract_beneficiaries
    contract_events
    contract_suspensions
    benefit_cycles
    validation_points
    validation_credentials
    contract_redemption_devices
    cycle_entitlement_subjects
    entitlement_allocations
    redemption_attempts
    redemptions
    redemption_reversals
    redemption_events
    entitlement_ledger_entries
    polo_platform_subscriptions
    platform_invoices
    platform_invoice_items
    platform_payments
    payment_provider_events
    legal_acceptances
    domain_events
    tenant_audit_events
    tenant_idempotency_keys
  )

  def up do
    execute("ALTER TABLE polos ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE polos FORCE ROW LEVEL SECURITY")

    execute("""
    CREATE POLICY polo_identity_isolation ON polos
    FOR ALL
    USING (
      id = NULLIF(current_setting('app.current_polo_id', true), '')::uuid
    )
    WITH CHECK (
      id = NULLIF(current_setting('app.current_polo_id', true), '')::uuid
    );
    """)

    Enum.each(@tenant_tables, fn table ->
      execute("ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY")
      execute("ALTER TABLE #{table} FORCE ROW LEVEL SECURITY")

      execute("""
      CREATE POLICY polo_isolation ON #{table}
      FOR ALL
      USING (
        polo_id = NULLIF(current_setting('app.current_polo_id', true), '')::uuid
      )
      WITH CHECK (
        polo_id = NULLIF(current_setting('app.current_polo_id', true), '')::uuid
      );
      """)
    end)

    execute("ALTER TABLE outbox_messages ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE outbox_messages FORCE ROW LEVEL SECURITY")

    execute("""
    CREATE POLICY outbox_polo_isolation ON outbox_messages
    FOR ALL
    USING (
      EXISTS (
        SELECT 1
        FROM domain_events
        WHERE domain_events.id = outbox_messages.domain_event_id
          AND domain_events.polo_id =
            NULLIF(current_setting('app.current_polo_id', true), '')::uuid
      )
    )
    WITH CHECK (
      EXISTS (
        SELECT 1
        FROM domain_events
        WHERE domain_events.id = outbox_messages.domain_event_id
          AND domain_events.polo_id =
            NULLIF(current_setting('app.current_polo_id', true), '')::uuid
      )
    );
    """)
  end

  def down do
    execute("DROP POLICY outbox_polo_isolation ON outbox_messages")
    execute("ALTER TABLE outbox_messages NO FORCE ROW LEVEL SECURITY")
    execute("ALTER TABLE outbox_messages DISABLE ROW LEVEL SECURITY")

    Enum.each(Enum.reverse(@tenant_tables), fn table ->
      execute("DROP POLICY polo_isolation ON #{table}")
      execute("ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY")
      execute("ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY")
    end)

    execute("DROP POLICY polo_identity_isolation ON polos")
    execute("ALTER TABLE polos NO FORCE ROW LEVEL SECURITY")
    execute("ALTER TABLE polos DISABLE ROW LEVEL SECURITY")
  end
end
