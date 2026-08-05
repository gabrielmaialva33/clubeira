defmodule Clubeira.Outbox.DatabaseContractTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Repo

  test "stale publishing claims have an index matching the recovery scan" do
    assert %{rows: [[definition]]} =
             Repo.query!("""
             SELECT indexdef
             FROM pg_indexes
             WHERE schemaname = 'public'
               AND indexname = 'outbox_messages_publishing_idx'
             """)

    assert definition =~ "(locked_at, id)"
    assert definition =~ "WHERE (status = 'publishing'::text)"
  end
end
