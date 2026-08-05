defmodule Clubeira.Reviews.DatabaseContractTest do
  use Clubeira.DataCase, async: true

  alias Clubeira.Repo

  test "the database arbitrates review identity and immutable revision history" do
    %{rows: index_rows} =
      Repo.query!("""
      SELECT indexdef
      FROM pg_indexes
      WHERE schemaname = 'public'
        AND tablename = 'reviews'
      """)

    index_definitions = Enum.map(index_rows, fn [definition] -> definition end)

    assert Enum.any?(index_definitions, fn definition ->
             definition =~ "UNIQUE" and definition =~ "(place_id, author_user_id)"
           end)

    assert Enum.any?(index_definitions, fn definition ->
             definition =~ "UNIQUE" and definition =~ "(source_redemption_id)" and
               definition =~ "WHERE (source_redemption_id IS NOT NULL)"
           end)

    assert %{rows: [["review_revisions_append_only"]]} =
             Repo.query!("""
             SELECT trigger.tgname
             FROM pg_trigger AS trigger
             JOIN pg_class AS table_class ON table_class.oid = trigger.tgrelid
             JOIN pg_namespace AS namespace ON namespace.oid = table_class.relnamespace
             WHERE namespace.nspname = 'public'
               AND table_class.relname = 'review_revisions'
               AND trigger.tgname = 'review_revisions_append_only'
               AND NOT trigger.tgisinternal
             """)
  end
end
