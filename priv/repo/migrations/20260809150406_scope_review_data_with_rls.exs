defmodule Clubeira.Repo.Migrations.ScopeReviewDataWithRls do
  use Ecto.Migration

  @polo_id "NULLIF(current_setting('app.current_polo_id', true), '')::uuid"

  def up do
    policies = %{
      "reviews" => root_review_sql(),
      "review_revisions" => review_sql("review_revisions.review_id"),
      "review_media" => media_sql(),
      "review_responses" => review_sql("review_responses.review_id"),
      "review_response_revisions" => response_revision_sql(),
      "review_reports" => review_sql("review_reports.review_id"),
      "moderation_actions" => review_sql("moderation_actions.review_id")
    }

    Enum.each(policies, fn {table, predicate} ->
      execute("ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY")
      execute("ALTER TABLE #{table} FORCE ROW LEVEL SECURITY")

      execute("""
      CREATE POLICY #{table}_polo_scope ON #{table}
      FOR ALL
      USING (#{predicate})
      WITH CHECK (#{predicate})
      """)
    end)
  end

  def down do
    Enum.each(
      ~w(
        moderation_actions
        review_reports
        review_response_revisions
        review_responses
        review_media
        review_revisions
        reviews
      ),
      fn table ->
        execute("DROP POLICY IF EXISTS #{table}_polo_scope ON #{table}")
        execute("ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY")
        execute("ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY")
      end
    )
  end

  defp review_sql(review_id) do
    """
    EXISTS (
      SELECT 1
      FROM reviews AS scoped_review
      JOIN redemptions AS redemption
        ON redemption.id = scoped_review.source_redemption_id
      WHERE scoped_review.id = #{review_id}
        AND redemption.polo_id = #{@polo_id}
    )
    """
  end

  defp root_review_sql do
    """
    EXISTS (
      SELECT 1
      FROM redemptions AS redemption
      WHERE redemption.id = reviews.source_redemption_id
        AND redemption.polo_id = #{@polo_id}
    )
    """
  end

  defp media_sql do
    """
    EXISTS (
      SELECT 1
      FROM review_revisions AS revision
      JOIN reviews AS scoped_review
        ON scoped_review.id = revision.review_id
      JOIN redemptions AS redemption
        ON redemption.id = scoped_review.source_redemption_id
      WHERE revision.id = review_media.review_revision_id
        AND redemption.polo_id = #{@polo_id}
    )
    """
  end

  defp response_revision_sql do
    """
    EXISTS (
      SELECT 1
      FROM review_responses AS response
      JOIN reviews AS scoped_review
        ON scoped_review.id = response.review_id
      JOIN redemptions AS redemption
        ON redemption.id = scoped_review.source_redemption_id
      WHERE response.id = review_response_revisions.review_response_id
        AND redemption.polo_id = #{@polo_id}
    )
    """
  end
end
