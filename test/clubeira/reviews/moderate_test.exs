defmodule Clubeira.Reviews.ModerateTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Reviews
  alias Clubeira.ReviewsFixtures
  alias Clubeira.Tenancy.Scope

  test "publishes a pending review with append-only evidence and atomic side effects" do
    fixture = ReviewsFixtures.pending_review!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)

    request = %{
      review_id: fixture.submission.review.id,
      action: "publish",
      reason: "Conteúdo verificado e adequado às diretrizes.",
      idempotency_key: "moderate-review-publish-001"
    }

    assert {:ok, result} = Reviews.moderate(moderator_scope, request)
    assert result.review.status == "published"
    assert %DateTime{} = result.review.published_at
    assert result.review.rejected_at == nil
    assert result.action.action == "publish"
    assert result.action.actor_user_id == moderator_scope.actor_user_id

    assert %{rows: [[1, 1, 1, 1, 1, "published", reason]]} =
             scoped_query!(fixture, """
             SELECT
               (SELECT count(*) FROM moderation_actions WHERE review_id = $1),
               (SELECT count(*) FROM tenant_audit_events
                  WHERE action = 'review.published' AND resource_id = $1),
               (SELECT count(*) FROM domain_events
                  WHERE event_type = 'review.published' AND aggregate_id = $1),
               (SELECT count(*) FROM outbox_messages
                  WHERE topic = 'reviews.published'),
               (SELECT count(*) FROM tenant_idempotency_keys
                  WHERE scope = 'reviews.moderate'),
               (SELECT status FROM reviews WHERE id = $1),
               (SELECT reason FROM moderation_actions WHERE review_id = $1)
             """, [fixture.submission.review.id])

    assert reason == request.reason

    assert %{rows: [[false, false, false]]} =
             scoped_query!(fixture, """
             SELECT
               EXISTS (
                 SELECT 1 FROM tenant_audit_events
                 WHERE action = 'review.published' AND metadata::text LIKE $2
               ),
               EXISTS (
                 SELECT 1 FROM domain_events
                 WHERE event_type = 'review.published' AND payload::text LIKE $2
               ),
               EXISTS (
                 SELECT 1 FROM outbox_messages
                 WHERE topic = 'reviews.published' AND payload::text LIKE $2
               )
             """, [fixture.submission.review.id, "%#{request.reason}%"])

    assert {:ok, replayed} = Reviews.moderate(moderator_scope, request)
    assert replayed.action.id == result.action.id
    assert replayed.review.id == result.review.id
  end

  test "rejects a review without publishing it" do
    fixture = ReviewsFixtures.pending_review!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)

    assert {:ok, result} =
             Reviews.moderate(moderator_scope, %{
               review_id: fixture.submission.review.id,
               action: "reject",
               reason: "O texto contém conteúdo incompatível com as diretrizes.",
               idempotency_key: "moderate-review-reject-001"
             })

    assert result.review.status == "rejected"
    assert result.review.published_at == nil
    assert %DateTime{} = result.review.rejected_at

    assert %{rows: [["reject", "review.rejected", "reviews.rejected"]]} =
             scoped_query!(fixture, """
             SELECT action.action, event.event_type, message.topic
             FROM moderation_actions AS action
             JOIN domain_events AS event ON event.aggregate_id = action.review_id
             JOIN outbox_messages AS message ON message.domain_event_id = event.id
             WHERE action.id = $1 AND event.aggregate_version = 2
             """, [result.action.id])
  end

  test "derives moderator authority from an active polo membership" do
    fixture = ReviewsFixtures.pending_review!()

    unprivileged_scope =
      Scope.new!(fixture.ids.polo,
        actor_user_id: fixture.ids.user,
        request_id: Ecto.UUID.generate(version: 7)
      )

    assert {:error, :moderator_required} =
             Reviews.moderate(unprivileged_scope, %{
               review_id: fixture.submission.review.id,
               action: "publish",
               reason: "Tentativa sem autorização.",
               idempotency_key: "moderate-review-forbidden"
             })

    assert %{rows: [[0]]} =
             scoped_query!(fixture, "SELECT count(*) FROM moderation_actions")
  end

  test "serializes the review state and rejects a second terminal action" do
    fixture = ReviewsFixtures.pending_review!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)

    assert {:ok, _published} =
             Reviews.moderate(moderator_scope, %{
               review_id: fixture.submission.review.id,
               action: "publish",
               reason: "Primeira decisão terminal.",
               idempotency_key: "moderate-review-terminal-first"
             })

    assert {:error, :invalid_review_transition} =
             Reviews.moderate(moderator_scope, %{
               review_id: fixture.submission.review.id,
               action: "reject",
               reason: "Segunda decisão não pode sobrescrever a primeira.",
               idempotency_key: "moderate-review-terminal-second"
             })

    assert %{rows: [[1, "published"]]} =
             scoped_query!(fixture, """
             SELECT
               (SELECT count(*) FROM moderation_actions WHERE review_id = $1),
               (SELECT status FROM reviews WHERE id = $1)
             """, [fixture.submission.review.id])
  end

  defp scoped_query!(fixture, sql, parameters \\ []) do
    Clubeira.RedemptionsFixtures.scoped_query!(fixture, sql, parameters)
  end
end
