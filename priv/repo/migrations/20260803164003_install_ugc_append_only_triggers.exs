defmodule Clubeira.Repo.Migrations.InstallUgcAppendOnlyTriggers do
  use Ecto.Migration

  def change do
    execute(
      """
      CREATE TRIGGER review_revisions_append_only
      BEFORE UPDATE OR DELETE ON review_revisions
      FOR EACH ROW
      EXECUTE FUNCTION clubeira_reject_immutable_mutation();
      """,
      "DROP TRIGGER review_revisions_append_only ON review_revisions"
    )

    execute(
      """
      CREATE TRIGGER review_response_revisions_append_only
      BEFORE UPDATE OR DELETE ON review_response_revisions
      FOR EACH ROW
      EXECUTE FUNCTION clubeira_reject_immutable_mutation();
      """,
      "DROP TRIGGER review_response_revisions_append_only ON review_response_revisions"
    )

    execute(
      """
      CREATE TRIGGER moderation_actions_append_only
      BEFORE UPDATE OR DELETE ON moderation_actions
      FOR EACH ROW
      EXECUTE FUNCTION clubeira_reject_immutable_mutation();
      """,
      "DROP TRIGGER moderation_actions_append_only ON moderation_actions"
    )
  end
end
