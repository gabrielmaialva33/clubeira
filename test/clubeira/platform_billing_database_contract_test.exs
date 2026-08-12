defmodule Clubeira.PlatformBilling.DatabaseContractTest do
  use Clubeira.DataCase, async: true

  alias Clubeira.Repo

  test "plan features and prices preserve the published version snapshot" do
    constraints = constraint_definitions()

    assert constraints["platform_plan_version_features_feature_fkey"] =~
             "FOREIGN KEY (platform_feature_id, value_kind)"

    assert constraints["platform_plan_version_features_feature_fkey"] =~
             "REFERENCES platform_features(id, value_kind)"

    assert constraints["platform_plan_version_features_value_check"] =~
             "value_kind = 'boolean'"

    assert constraints["platform_plan_version_features_value_check"] =~
             "value_kind = 'integer'"

    assert constraints["polo_platform_subscriptions_price_fkey"] =~
             "FOREIGN KEY (platform_price_id, platform_plan_version_id)"

    assert constraints["polo_platform_subscriptions_price_fkey"] =~
             "REFERENCES platform_prices(id, platform_plan_version_id)"
  end

  test "subscription reservation and invoice settlement keep polo and merchant dimensions" do
    constraints = constraint_definitions()
    indexes = index_definitions()

    assert constraints["polo_platform_subscriptions_reservation_check"] =~ "request_sha256"

    assert constraints["platform_invoices_subscription_fkey"] =~
             "FOREIGN KEY (polo_platform_subscription_id, polo_id, merchant_account_id)"

    assert constraints["platform_payments_invoice_fkey"] =~
             "FOREIGN KEY (platform_invoice_id, polo_id, merchant_account_id)"

    assert indexes["polo_platform_subscriptions_current_uidx"] =~ "(polo_id)"
    assert indexes["polo_platform_subscriptions_current_uidx"] =~ "WHERE"

    assert indexes["polo_platform_subscriptions_actor_idempotency_uidx"] =~
             "(polo_id, requested_by_user_id, idempotency_key)"

    assert indexes["platform_invoices_provider_reference_uidx"] =~
             "(merchant_account_id, provider_reference)"

    assert indexes["platform_payments_provider_reference_uidx"] =~
             "(merchant_account_id, provider_reference)"
  end

  test "managed platform plan inventory has an index matching its keyset order" do
    indexes = index_definitions()

    assert indexes["platform_plans_management_feed_idx"] =~
             "(inserted_at, id)"
  end

  defp constraint_definitions do
    %{rows: rows} =
      Repo.query!("""
      SELECT constraint_record.conname, pg_get_constraintdef(constraint_record.oid)
      FROM pg_constraint AS constraint_record
      WHERE constraint_record.conname IN (
        'platform_plan_version_features_feature_fkey',
        'platform_plan_version_features_value_check',
        'polo_platform_subscriptions_price_fkey',
        'polo_platform_subscriptions_reservation_check',
        'platform_invoices_subscription_fkey',
        'platform_payments_invoice_fkey'
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
          'polo_platform_subscriptions_current_uidx',
          'polo_platform_subscriptions_actor_idempotency_uidx',
          'platform_invoices_provider_reference_uidx',
          'platform_payments_provider_reference_uidx',
          'platform_plans_management_feed_idx'
        )
      """)

    Map.new(rows, fn [name, definition] -> {name, definition} end)
  end
end
