defmodule Clubeira.Redemptions.DatabaseContractTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Repo

  test "redemption reversals are append-only and do not restore entitlements implicitly" do
    %{rows: rows} =
      Repo.query!("""
      SELECT trigger.tgname
      FROM pg_trigger AS trigger
      JOIN pg_class AS table_class ON table_class.oid = trigger.tgrelid
      JOIN pg_namespace AS namespace ON namespace.oid = table_class.relnamespace
      WHERE namespace.nspname = 'public'
        AND table_class.relname = 'redemption_reversals'
        AND NOT trigger.tgisinternal
      ORDER BY trigger.tgname
      """)

    trigger_names = Enum.map(rows, fn [name] -> name end)

    assert "redemption_reversals_append_only" in trigger_names
    refute "redemption_reversals_restore_entitlement" in trigger_names

    assert %{rows: [[nil]]} =
             Repo.query!("SELECT to_regprocedure('clubeira_restore_entitlement()')")
  end

  test "a redemption must preserve the package item and validation point from its attempt" do
    assert %{rows: [[definition]]} =
             Repo.query!("""
             SELECT pg_get_constraintdef(db_constraint.oid)
             FROM pg_constraint AS db_constraint
             JOIN pg_class AS table_class ON table_class.oid = db_constraint.conrelid
             JOIN pg_namespace AS namespace ON namespace.oid = table_class.relnamespace
             WHERE namespace.nspname = 'public'
               AND table_class.relname = 'redemptions'
               AND db_constraint.conname = 'redemptions_attempt_fkey'
             """)

    assert definition =~ "benefit_package_item_id"
    assert definition =~ "validation_point_id"
  end

  test "member history has an index matching its tenant, actor, and cursor order" do
    assert %{rows: [[definition]]} =
             Repo.query!("""
             SELECT indexdef
             FROM pg_indexes
             WHERE schemaname = 'public'
               AND indexname = 'redemption_attempts_member_history_idx'
             """)

    assert definition =~ "(polo_id, requesting_user_id, requested_at, id)"
  end

  test "validation API keys have one indexed non-recoverable identity" do
    assert %{rows: [[definition]]} =
             Repo.query!("""
             SELECT indexdef
             FROM pg_indexes
             WHERE schemaname = 'public'
               AND indexname = 'validation_credentials_secret_hash_uidx'
             """)

    assert definition =~ "UNIQUE"
    assert definition =~ "(secret_hash)"
    assert definition =~ "WHERE (secret_hash IS NOT NULL)"
  end

  test "validation API keys use an explicit credential kind" do
    assert %{rows: [[definition]]} =
             Repo.query!("""
             SELECT pg_get_constraintdef(db_constraint.oid)
             FROM pg_constraint AS db_constraint
             JOIN pg_class AS table_class ON table_class.oid = db_constraint.conrelid
             WHERE table_class.relname = 'validation_credentials'
               AND db_constraint.conname = 'validation_credentials_kind_check'
             """)

    assert definition =~ "'api_key'"
  end

  test "validation points persist one positive monotonic stream revision" do
    assert %{rows: [["NO", "1"]]} =
             Repo.query!("""
             SELECT is_nullable, column_default
             FROM information_schema.columns
             WHERE table_schema = 'public'
               AND table_name = 'validation_points'
               AND column_name = 'revision'
             """)

    assert %{rows: [[definition]]} =
             Repo.query!("""
             SELECT pg_get_constraintdef(db_constraint.oid)
             FROM pg_constraint AS db_constraint
             WHERE db_constraint.conrelid = 'public.validation_points'::regclass
               AND db_constraint.conname = 'validation_points_revision_check'
             """)

    assert definition =~ "revision > 0"
  end
end
