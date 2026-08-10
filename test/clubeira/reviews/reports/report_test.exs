defmodule Clubeira.Reviews.ReportTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Factory
  alias Clubeira.Reviews
  alias Clubeira.ReviewsFixtures
  alias Clubeira.Tenancy.Scope

  test "opens an idempotent report without leaking its free-form details" do
    fixture = published_review!()
    reporter_scope = reporter_scope(fixture)

    request = %{
      place_id: fixture.ids.place,
      review_id: fixture.submission.review.id,
      reason_code: "personal_data",
      details: "A publicação expõe um telefone pessoal completo.",
      idempotency_key: "report-review-private-details-001"
    }

    assert {:ok, report} = Reviews.report(reporter_scope, request)
    assert report["review_id"] == fixture.submission.review.id
    assert report["reason_code"] == "personal_data"
    assert report["status"] == "open"
    refute Map.has_key?(report, "details")

    assert %{rows: [["open", details, 1, 1, 1, 1]]} =
             scoped_query!(
               fixture,
               """
               SELECT
                 (SELECT status FROM review_reports WHERE id = $1),
                 (SELECT details FROM review_reports WHERE id = $1),
                 (SELECT count(*) FROM tenant_audit_events
                    WHERE action = 'review.reported' AND resource_id = $1),
                 (SELECT count(*) FROM domain_events
                    WHERE event_type = 'review.reported' AND aggregate_id = $1),
                 (SELECT count(*) FROM outbox_messages
                    WHERE topic = 'reviews.reports.opened'),
                 (SELECT count(*) FROM tenant_idempotency_keys
                    WHERE scope = 'reviews.report')
               """,
               [report["id"]]
             )

    assert details == request.details

    assert %{rows: [[false, false, false]]} =
             scoped_query!(
               fixture,
               """
               SELECT
                 EXISTS (
                   SELECT 1 FROM tenant_audit_events
                   WHERE action = 'review.reported' AND metadata::text LIKE $1
                 ),
                 EXISTS (
                   SELECT 1 FROM domain_events
                   WHERE event_type = 'review.reported' AND payload::text LIKE $1
                 ),
                 EXISTS (
                   SELECT 1 FROM outbox_messages
                   WHERE topic = 'reviews.reports.opened' AND payload::text LIKE $1
                 )
               """,
               ["%#{request.details}%"]
             )

    assert {:ok, replayed} = Reviews.report(reporter_scope, request)
    assert replayed == report
  end

  test "arbitrates one open report per member and review" do
    fixture = published_review!()
    reporter_scope = reporter_scope(fixture)

    base = %{
      place_id: fixture.ids.place,
      review_id: fixture.submission.review.id,
      reason_code: "spam"
    }

    assert {:ok, _report} =
             Reviews.report(
               reporter_scope,
               Map.put(base, :idempotency_key, "report-review-unique-open-001")
             )

    assert {:error, :review_already_reported} =
             Reviews.report(
               reporter_scope,
               Map.put(base, :idempotency_key, "report-review-unique-open-002")
             )

    assert %{rows: [[1, 2]]} =
             scoped_query!(
               fixture,
               """
               SELECT
                 (SELECT count(*) FROM review_reports WHERE review_id = $1),
                 (SELECT count(*) FROM tenant_idempotency_keys
                    WHERE scope = 'reviews.report')
               """,
               [fixture.submission.review.id]
             )
  end

  test "requires details for the generic reason code" do
    fixture = published_review!()

    assert {:error, %Ecto.Changeset{} = changeset} =
             Reviews.report(reporter_scope(fixture), %{
               place_id: fixture.ids.place,
               review_id: fixture.submission.review.id,
               reason_code: "other",
               idempotency_key: "report-review-other-no-details"
             })

    assert "is required for other" in errors_on(changeset).details
  end

  test "rejects a new report when the polo is not operational" do
    fixture = published_review!()
    reporter_scope = reporter_scope(fixture)

    assert %{num_rows: 1} =
             scoped_query!(
               fixture,
               "UPDATE polos SET status = 'suspended' WHERE id = $1",
               [fixture.ids.polo]
             )

    assert {:error, :polo_unavailable} =
             Reviews.report(reporter_scope, %{
               place_id: fixture.ids.place,
               review_id: fixture.submission.review.id,
               reason_code: "spam",
               idempotency_key: "report-review-inactive-polo"
             })

    assert %{rows: [[0, 0, 0, "failed"]]} =
             scoped_query!(
               fixture,
               """
               SELECT
                 (SELECT count(*) FROM review_reports WHERE review_id = $1),
                 (SELECT count(*) FROM domain_events
                    WHERE event_type = 'review.reported' AND aggregate_id = $1),
                 (SELECT count(*) FROM outbox_messages
                    WHERE topic = 'reviews.reports.opened'),
                 (SELECT status FROM tenant_idempotency_keys
                    WHERE scope = 'reviews.report' AND user_id = $2)
               """,
               [fixture.submission.review.id, reporter_scope.actor_user_id]
             )
  end

  defp published_review! do
    fixture = ReviewsFixtures.pending_review!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)

    assert {:ok, _result} =
             Reviews.moderate(moderator_scope, %{
               review_id: fixture.submission.review.id,
               action: "publish",
               reason: "Conteúdo adequado para publicação.",
               idempotency_key: "publish-before-report-domain-#{Ecto.UUID.generate()}"
             })

    fixture
  end

  defp reporter_scope(fixture) do
    reporter = Factory.insert(:user)

    Scope.new!(fixture.ids.polo,
      actor_user_id: reporter.id,
      request_id: Ecto.UUID.generate(version: 7)
    )
  end

  defp scoped_query!(fixture, sql, parameters) do
    Clubeira.RedemptionsFixtures.scoped_query!(fixture, sql, parameters)
  end
end
