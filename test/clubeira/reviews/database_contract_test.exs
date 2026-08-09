defmodule Clubeira.Reviews.DatabaseContractTest do
  use Clubeira.DataCase, async: true

  alias Clubeira.Repo

  @review_graph_tables ~w(
    moderation_actions
    review_media
    review_reports
    review_response_revisions
    review_responses
    review_revisions
    reviews
  )

  test "the complete review graph is protected by forced polo RLS" do
    assert %{rows: rows} =
             Repo.query!(
               """
               SELECT
                 class.relname,
                 class.relrowsecurity,
                 class.relforcerowsecurity,
                 count(policy.oid) > 0 AS has_policy
               FROM pg_class AS class
               JOIN pg_namespace AS namespace ON namespace.oid = class.relnamespace
               LEFT JOIN pg_policy AS policy ON policy.polrelid = class.oid
               WHERE namespace.nspname = 'public'
                 AND class.relname = ANY($1::text[])
               GROUP BY class.relname, class.relrowsecurity, class.relforcerowsecurity
               ORDER BY class.relname
               """,
               [@review_graph_tables]
             )

    assert rows == Enum.map(@review_graph_tables, &[&1, true, true, true])
  end

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

  test "moderation and public feeds have indexes matching their keyset order" do
    assert %{rows: rows} =
             Repo.query!("""
             SELECT indexname, indexdef
             FROM pg_indexes
             WHERE schemaname = 'public'
               AND indexname IN ('reviews_moderation_queue_idx', 'reviews_public_feed_idx')
             ORDER BY indexname
             """)

    assert [
             ["reviews_moderation_queue_idx", moderation_definition],
             ["reviews_public_feed_idx", public_definition]
           ] = rows

    assert moderation_definition =~ "(status, inserted_at, id)"
    assert public_definition =~ "(place_id, published_at, id)"
    assert public_definition =~ "WHERE (status = 'published'::text)"
  end

  test "review reports arbitrate one resolution and follow their keyset order" do
    assert %{rows: rows} =
             Repo.query!("""
             SELECT indexname, indexdef
             FROM pg_indexes
             WHERE schemaname = 'public'
               AND indexname IN (
                 'review_reports_status_keyset_idx',
                 'moderation_actions_review_report_uidx'
               )
             ORDER BY indexname
             """)

    assert [
             ["moderation_actions_review_report_uidx", resolution_definition],
             ["review_reports_status_keyset_idx", report_definition]
           ] = rows

    assert resolution_definition =~ "UNIQUE"
    assert resolution_definition =~ "(review_report_id)"
    assert resolution_definition =~ "WHERE (review_report_id IS NOT NULL)"
    assert report_definition =~ "(status, inserted_at, id)"
  end
end
