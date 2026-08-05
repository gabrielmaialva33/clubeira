defmodule Clubeira.Accounts.DatabaseContractTest do
  use Clubeira.DataCase, async: true

  test "password reset credentials enforce digest, lifecycle, and one-open-token invariants" do
    constraints = constraint_definitions()

    assert constraints["user_password_reset_tokens_hash_check"] =~
             "octet_length(token_hash) = 32"

    assert constraints["user_password_reset_tokens_dates_check"] =~
             "expires_at > inserted_at"

    terminal_state = constraints["user_password_reset_tokens_terminal_state_check"]
    assert terminal_state =~ "consumed_at IS NULL"
    assert terminal_state =~ "revoked_at IS NULL"
    assert terminal_state =~ " OR "

    assert constraints["user_password_reset_tokens_user_id_fkey"] =~
             "FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE RESTRICT"

    assert %{rows: [[index_definition]]} =
             Repo.query!("""
             SELECT indexdef
             FROM pg_indexes
             WHERE schemaname = 'public'
               AND indexname = 'user_password_reset_tokens_one_active_per_user_idx'
             """)

    assert index_definition =~ "UNIQUE INDEX"
    assert index_definition =~ "(user_id)"
    assert index_definition =~ "consumed_at IS NULL"
    assert index_definition =~ "revoked_at IS NULL"
  end

  test "password reset credentials remain global instead of tenant-scoped" do
    assert %{rows: [[false, false]]} =
             Repo.query!("""
             SELECT relrowsecurity, relforcerowsecurity
             FROM pg_class
             WHERE oid = 'public.user_password_reset_tokens'::regclass
             """)

    assert %{rows: []} =
             Repo.query!("""
             SELECT column_name
             FROM information_schema.columns
             WHERE table_schema = 'public'
               AND table_name = 'user_password_reset_tokens'
               AND column_name = 'polo_id'
             """)
  end

  defp constraint_definitions do
    %{rows: rows} =
      Repo.query!("""
      SELECT constraint_record.conname, pg_get_constraintdef(constraint_record.oid)
      FROM pg_constraint AS constraint_record
      WHERE constraint_record.conrelid = 'public.user_password_reset_tokens'::regclass
      """)

    Map.new(rows, fn [name, definition] -> {name, definition} end)
  end
end
