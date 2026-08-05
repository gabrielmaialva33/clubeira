defmodule Clubeira.Reviews.SubmitVerifiedTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Redemptions
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Reviews

  test "persists the review, revision, audit, event, outbox, and idempotency atomically" do
    fixture = RedemptionsFixtures.create!()
    assert {:ok, redemption} = Redemptions.confirm(fixture.scope, fixture.request)

    attributes = %{
      place_id: fixture.ids.place,
      source_redemption_id: redemption.id,
      rating: 5,
      title: "Muito bom",
      body: "Este texto fica no histórico da avaliação, não no evento.",
      idempotency_key: "review-context-001"
    }

    assert {:ok, %{review: review, revision: revision}} =
             Reviews.submit_verified(fixture.scope, attributes)

    assert review.status == "pending"
    assert review.verification_kind == "verified"
    assert revision.review_id == review.id
    assert revision.revision_number == 1

    assert %{rows: [[1, 1, 1, 1, 1, "completed", false, false]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 (SELECT count(*) FROM reviews WHERE id = $1),
                 (SELECT count(*) FROM review_revisions WHERE review_id = $1),
                 (SELECT count(*) FROM tenant_audit_events
                    WHERE action = 'review.submitted' AND resource_id = $1),
                 (SELECT count(*) FROM domain_events
                    WHERE event_type = 'review.submitted' AND aggregate_id = $1),
                 (SELECT count(*) FROM outbox_messages
                    WHERE topic = 'reviews.submitted'),
                 idempotency.status,
                 event.payload ? 'title',
                 event.payload ? 'body'
               FROM tenant_idempotency_keys AS idempotency
               JOIN domain_events AS event
                 ON event.aggregate_id = idempotency.resource_id
                AND event.event_type = 'review.submitted'
               WHERE idempotency.resource_id = $1
               """,
               [review.id]
             )
  end
end
