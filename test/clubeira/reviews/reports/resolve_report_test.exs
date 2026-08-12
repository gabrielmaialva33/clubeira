defmodule Clubeira.Reviews.ResolveReportTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Factory
  alias Clubeira.Reviews
  alias Clubeira.Reviews.ReviewReportResolutionRequest
  alias Clubeira.ReviewsFixtures
  alias Clubeira.Tenancy.Scope

  test "the report-resolution form boundary rejects non-map and struct payloads without raising" do
    Enum.each([:invalid, %Clubeira.Reviews.ReviewReportResolutionRequest{}], fn attributes ->
      changeset = Reviews.change_review_report_resolution_request(attributes)

      refute changeset.valid?
      assert {:base, {"must be a map", []}} in changeset.errors
    end)
  end

  test "the report-resolution command normalizes decisions and rejects malformed terms" do
    report_id = Ecto.UUID.generate(version: 7)

    assert {:ok, request} =
             ReviewReportResolutionRequest.new(%{
               review_report_id: report_id,
               action: " HIDE ",
               reason: "  Viola as diretrizes.  ",
               idempotency_key: "resolve-report-request-001"
             })

    assert request.action == "hide"
    assert request.reason == "Viola as diretrizes."

    for attributes <- [
          :invalid,
          %ReviewReportResolutionRequest{},
          %{
            review_report_id: report_id,
            action: 1,
            reason: 2,
            idempotency_key: "invalid key"
          }
        ] do
      assert {:error, changeset} = ReviewReportResolutionRequest.new(attributes)
      refute changeset.valid?
    end
  end

  test "accepts a report by hiding its review with atomic private evidence" do
    fixture = open_report!()

    request = %{
      review_report_id: fixture.report["id"],
      action: "hide",
      reason: "A denúncia foi confirmada pela equipe responsável.",
      idempotency_key: "resolve-report-hide-001"
    }

    assert {:ok, result} = Reviews.resolve_report(fixture.moderator_scope, request)
    assert result["review_report_id"] == fixture.report["id"]
    assert result["review_id"] == fixture.submission.review.id
    assert result["action"] == "hide"
    assert result["report_status"] == "accepted"
    assert result["review_status"] == "hidden"
    refute Map.has_key?(result, "reason")

    assert %{
             rows: [
               [
                 "accepted",
                 "hidden",
                 "hide",
                 reason,
                 2,
                 2,
                 2,
                 1
               ]
             ]
           } =
             scoped_query!(
               fixture,
               """
               SELECT
                 (SELECT status FROM review_reports WHERE id = $1),
                 (SELECT status FROM reviews WHERE id = $2),
                 (SELECT action FROM moderation_actions WHERE review_report_id = $1),
                 (SELECT reason FROM moderation_actions WHERE review_report_id = $1),
                 (SELECT count(*) FROM tenant_audit_events
                    WHERE action IN ('review.report.accepted', 'review.hidden')),
                 (SELECT count(*) FROM domain_events
                    WHERE event_type IN ('review.report.accepted', 'review.hidden')),
                 (SELECT count(*) FROM outbox_messages
                    WHERE topic IN ('reviews.reports.accepted', 'reviews.hidden')),
                 (SELECT count(*) FROM tenant_idempotency_keys
                    WHERE scope = 'reviews.resolve_report')
               """,
               [fixture.report["id"], fixture.submission.review.id]
             )

    assert reason == request.reason

    assert %{rows: [[false, false, false]]} =
             scoped_query!(
               fixture,
               """
               SELECT
                 EXISTS (
                   SELECT 1 FROM tenant_audit_events
                   WHERE action IN ('review.report.accepted', 'review.hidden')
                     AND metadata::text LIKE $1
                 ),
                 EXISTS (
                   SELECT 1 FROM domain_events
                   WHERE event_type IN ('review.report.accepted', 'review.hidden')
                     AND payload::text LIKE $1
                 ),
                 EXISTS (
                   SELECT 1 FROM outbox_messages
                   WHERE topic IN ('reviews.reports.accepted', 'reviews.hidden')
                     AND payload::text LIKE $1
                 )
               """,
               ["%#{request.reason}%"]
             )

    assert {:ok, replayed} = Reviews.resolve_report(fixture.moderator_scope, request)
    assert replayed == result
  end

  test "dismisses a report while keeping the published review visible" do
    fixture = open_report!()

    assert {:ok, result} =
             Reviews.resolve_report(fixture.moderator_scope, %{
               review_report_id: fixture.report["id"],
               action: "dismiss",
               reason: "A publicação não viola as diretrizes do clube.",
               idempotency_key: "resolve-report-dismiss-001"
             })

    assert result["action"] == "dismiss"
    assert result["report_status"] == "rejected"
    assert result["review_status"] == "published"

    assert %{rows: [["rejected", "published", "close_report", 1, 1, 1, 0]]} =
             scoped_query!(
               fixture,
               """
               SELECT
                 (SELECT status FROM review_reports WHERE id = $1),
                 (SELECT status FROM reviews WHERE id = $2),
                 (SELECT action FROM moderation_actions WHERE review_report_id = $1),
                 (SELECT count(*) FROM tenant_audit_events
                    WHERE action = 'review.report.rejected'),
                 (SELECT count(*) FROM domain_events
                    WHERE event_type = 'review.report.rejected'),
                 (SELECT count(*) FROM outbox_messages
                    WHERE topic = 'reviews.reports.rejected'),
                 (SELECT count(*) FROM domain_events
                    WHERE event_type IN ('review.hidden', 'review.removed'))
               """,
               [fixture.report["id"], fixture.submission.review.id]
             )
  end

  test "accepts a report by removing its published review" do
    fixture = open_report!()

    assert {:ok, result} =
             Reviews.resolve_report(fixture.moderator_scope, %{
               review_report_id: fixture.report["id"],
               action: "remove",
               reason: "A publicação deve ser removida definitivamente.",
               idempotency_key: "resolve-report-remove-001"
             })

    assert result["report_status"] == "accepted"
    assert result["review_status"] == "removed"

    assert %{rows: [["accepted", "removed", "remove", 3]]} =
             scoped_query!(
               fixture,
               """
               SELECT
                 (SELECT status FROM review_reports WHERE id = $1),
                 (SELECT status FROM reviews WHERE id = $2),
                 (SELECT action FROM moderation_actions WHERE review_report_id = $1),
                 (SELECT aggregate_version FROM domain_events
                    WHERE aggregate_type = 'review' AND aggregate_id = $2
                    ORDER BY aggregate_version DESC LIMIT 1)
               """,
               [fixture.report["id"], fixture.submission.review.id]
             )
  end

  test "requires an active moderator and keeps the report open" do
    fixture = open_report!()

    assert {:error, :moderator_required} =
             Reviews.resolve_report(fixture.reporter_scope, %{
               review_report_id: fixture.report["id"],
               action: "hide",
               reason: "Tentativa sem autoridade de moderação.",
               idempotency_key: "resolve-report-forbidden"
             })

    assert %{rows: [["open", "published", 0]]} =
             scoped_query!(
               fixture,
               """
               SELECT
                 (SELECT status FROM review_reports WHERE id = $1),
                 (SELECT status FROM reviews WHERE id = $2),
                 (SELECT count(*) FROM moderation_actions WHERE review_report_id = $1)
               """,
               [fixture.report["id"], fixture.submission.review.id]
             )
  end

  defp open_report! do
    fixture = ReviewsFixtures.pending_review!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)

    assert {:ok, _moderation} =
             Reviews.moderate(moderator_scope, %{
               review_id: fixture.submission.review.id,
               action: "publish",
               reason: "Conteúdo adequado para publicação.",
               idempotency_key: "publish-before-report-resolution-#{Ecto.UUID.generate()}"
             })

    reporter = Factory.insert(:user)

    reporter_scope =
      Scope.new!(fixture.ids.polo,
        actor_user_id: reporter.id,
        request_id: Ecto.UUID.generate(version: 7)
      )

    assert {:ok, report} =
             Reviews.report(reporter_scope, %{
               place_id: fixture.ids.place,
               review_id: fixture.submission.review.id,
               reason_code: "offensive_content",
               details: "Conteúdo ofensivo identificado após a publicação.",
               idempotency_key: "report-before-resolution-#{Ecto.UUID.generate()}"
             })

    fixture
    |> Map.put(:moderator_scope, moderator_scope)
    |> Map.put(:reporter_scope, reporter_scope)
    |> Map.put(:report, report)
  end

  defp scoped_query!(fixture, sql, parameters) do
    Clubeira.RedemptionsFixtures.scoped_query!(fixture, sql, parameters)
  end
end
