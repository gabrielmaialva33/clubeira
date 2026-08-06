defmodule Clubeira.Billing.DatabaseContractTest do
  use Clubeira.DataCase, async: true

  alias Clubeira.Repo

  test "commercial and contract references preserve their versioned snapshot" do
    definitions = constraint_definitions()

    assert definitions["order_items_price_fkey"] =~
             "FOREIGN KEY (offering_price_id, polo_id, product_offering_version_id)"

    assert definitions["order_items_price_fkey"] =~
             "REFERENCES offering_prices(id, polo_id, product_offering_version_id)"

    assert definitions["access_contracts_order_item_fkey"] =~
             "FOREIGN KEY (order_item_id, polo_id, product_offering_version_id)"

    assert definitions["access_contracts_order_item_fkey"] =~
             "REFERENCES order_items(id, polo_id, product_offering_version_id)"
  end

  test "payment references cannot mix merchant accounts" do
    definitions = constraint_definitions()

    assert definitions["payment_provider_events_account_fkey"] =~
             "FOREIGN KEY (merchant_account_id, payment_provider_id)"

    assert definitions["payment_provider_events_account_fkey"] =~
             "REFERENCES merchant_accounts(id, payment_provider_id)"

    assert definitions["payment_provider_events_polo_merchant_account_fkey"] =~
             "FOREIGN KEY (polo_id, merchant_account_id)"

    assert definitions["payment_provider_events_polo_merchant_account_fkey"] =~
             "REFERENCES polo_merchant_accounts(polo_id, merchant_account_id)"

    assert definitions["payment_intents_polo_merchant_account_fkey"] =~
             "FOREIGN KEY (polo_id, merchant_account_id)"

    assert definitions["payments_intent_fkey"] =~
             "FOREIGN KEY (payment_intent_id, polo_id, merchant_account_id)"

    assert definitions["payments_intent_fkey"] =~
             "REFERENCES payment_intents(id, polo_id, merchant_account_id)"
  end

  test "cycle and allocation references preserve package dimensions" do
    definitions = constraint_definitions()

    assert definitions["benefit_cycles_package_assignment_fkey"] =~
             "FOREIGN KEY (offering_package_assignment_id, polo_id, benefit_package_version_id)"

    assert definitions["entitlement_allocations_package_item_fkey"] =~
             "FOREIGN KEY (benefit_package_item_id, polo_id, entitlement_scope_id, allocation_kind)"
  end

  test "database arbitrates checkout ownership and one live payment path" do
    definitions = index_definitions()

    assert definitions["orders_actor_idempotency_uidx"] =~
             "(polo_id, purchaser_user_id, idempotency_key)"

    assert definitions["access_contracts_order_item_uidx"] =~ "(polo_id, order_item_id)"

    assert definitions["payment_intents_live_order_uidx"] =~ "(polo_id, order_id)"
    assert definitions["payment_intents_live_order_uidx"] =~ "WHERE"
    assert definitions["payment_intents_live_order_uidx"] =~ "status"
  end

  test "payment checkout actions stay normalized and constrained" do
    definitions = constraint_definitions()

    assert definitions["payment_intents_payment_method_check"] =~
             "payment_method = 'pix'::text"

    assert definitions["payment_intents_next_action_check"] =~
             "jsonb_typeof(next_action) = 'object'::text"

    %{rows: [["NO", "'{}'::jsonb"]]} =
      Repo.query!("""
      SELECT is_nullable, column_default
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'payment_intents'
        AND column_name = 'next_action'
      """)
  end

  test "full refunds preserve tenant identity and arbitrate one financial reversal" do
    constraints = constraint_definitions()
    indexes = index_definitions()

    assert constraints["refunds_payment_fkey"] =~ "FOREIGN KEY (payment_id, polo_id)"
    assert constraints["refunds_payment_fkey"] =~ "REFERENCES payments(id, polo_id)"
    assert constraints["refunds_resolution_check"] =~ "provider_reference IS NOT NULL"
    assert constraints["payments_refunded_at_check"] =~ "refunded_at IS NOT NULL"

    assert constraints["entitlement_ledger_entries_kind_check"] =~ "refund_revocation"
    assert constraints["entitlement_ledger_entries_kind_check"] =~ "delta_units < 0"

    assert indexes["refunds_actor_idempotency_uidx"] =~
             "(polo_id, requested_by_user_id, idempotency_key)"

    assert indexes["refunds_live_payment_uidx"] =~ "(polo_id, payment_id)"
    assert indexes["refunds_live_payment_uidx"] =~ "requested"
    assert indexes["refunds_succeeded_payment_uidx"] =~ "status = 'succeeded'"
  end

  test "backoffice payment feeds have indexes matching both keyset query shapes" do
    indexes = index_definitions()

    assert indexes["payments_backoffice_feed_idx"] =~ "(polo_id, inserted_at, id)"

    assert indexes["payments_backoffice_status_feed_idx"] =~
             "(polo_id, status, inserted_at, id)"

    assert indexes["refunds_backoffice_payment_feed_idx"] =~
             "(polo_id, payment_id, inserted_at, id)"
  end

  defp constraint_definitions do
    %{rows: rows} =
      Repo.query!("""
      SELECT constraint_record.conname, pg_get_constraintdef(constraint_record.oid)
      FROM pg_constraint AS constraint_record
      WHERE constraint_record.conname IN (
        'order_items_price_fkey',
        'access_contracts_order_item_fkey',
        'payment_provider_events_account_fkey',
        'payment_provider_events_polo_merchant_account_fkey',
        'payment_intents_polo_merchant_account_fkey',
        'payment_intents_payment_method_check',
        'payment_intents_next_action_check',
        'payments_refunded_at_check',
        'payments_intent_fkey',
        'refunds_payment_fkey',
        'refunds_resolution_check',
        'benefit_cycles_package_assignment_fkey',
        'entitlement_allocations_package_item_fkey',
        'entitlement_ledger_entries_kind_check'
      )
      """)

    Map.new(rows, fn [name, definition] -> {name, definition} end)
  end

  defp index_definitions do
    %{rows: rows} =
      Repo.query!("""
      SELECT indexname, indexdef
      FROM pg_indexes
      WHERE schemaname = 'public'
        AND indexname IN (
          'orders_actor_idempotency_uidx',
          'access_contracts_order_item_uidx',
          'payment_intents_live_order_uidx',
          'payments_backoffice_feed_idx',
          'payments_backoffice_status_feed_idx',
          'refunds_backoffice_payment_feed_idx',
          'refunds_actor_idempotency_uidx',
          'refunds_live_payment_uidx',
          'refunds_succeeded_payment_uidx'
        )
      """)

    Map.new(rows, fn [name, definition] -> {name, definition} end)
  end
end
