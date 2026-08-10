defmodule Clubeira.Reviews.ConcurrencyTest do
  use Clubeira.ConcurrencyCase, async: false

  alias Clubeira.Factory
  alias Clubeira.Redemptions
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Reviews
  alias Clubeira.ReviewsFixtures
  alias Clubeira.Tenancy.Scope

  test "serializes competing submissions for the same member and place", %{repo: repo} do
    fixture = RedemptionsFixtures.create!()
    assert {:ok, redemption} = Redemptions.confirm(fixture.scope, fixture.request)

    base_attributes = %{
      place_id: fixture.ids.place,
      source_redemption_id: redemption.id,
      rating: 5,
      body: "Avaliação concorrente."
    }

    results =
      run_concurrently(repo, [
        fn ->
          Reviews.submit_verified(
            fixture.scope,
            Map.put(base_attributes, :idempotency_key, "review-concurrent-001")
          )
        end,
        fn ->
          Reviews.submit_verified(
            fixture.scope,
            Map.put(base_attributes, :idempotency_key, "review-concurrent-002")
          )
        end
      ])

    assert Enum.count(results, &match?({:ok, _submission}, &1)) == 1
    assert Enum.count(results, &match?({:error, :review_already_exists}, &1)) == 1

    assert %{rows: [[1, 1, 1, 1, 1, 2]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 (SELECT count(*) FROM reviews WHERE place_id = $1),
                 (SELECT count(*) FROM review_revisions WHERE review_id = $2),
                 (SELECT count(*) FROM tenant_audit_events
                    WHERE action = 'review.submitted' AND resource_id = $2),
                 (SELECT count(*) FROM domain_events
                    WHERE event_type = 'review.submitted' AND aggregate_id = $2),
                 (SELECT count(*) FROM outbox_messages AS message
                    JOIN domain_events AS event ON event.id = message.domain_event_id
                    WHERE message.topic = 'reviews.submitted' AND event.aggregate_id = $2),
                 (SELECT count(*) FROM tenant_idempotency_keys
                    WHERE scope = 'reviews.submit_verified' AND user_id = $3)
               """,
               [fixture.ids.place, review_id(results), fixture.ids.user]
             )
  end

  test "serializes competing terminal decisions for one review report", %{repo: repo} do
    fixture = ReviewsFixtures.pending_review!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)

    assert {:ok, _published} =
             Reviews.moderate(moderator_scope, %{
               review_id: fixture.submission.review.id,
               action: "publish",
               reason: "Publicação aprovada antes da denúncia concorrente.",
               idempotency_key: "publish-before-report-race"
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
               reason_code: "fraud",
               details: "Relato a ser decidido sob concorrência real.",
               idempotency_key: "report-before-resolution-race"
             })

    base_request = %{
      review_report_id: report["id"],
      action: "hide",
      reason: "A denúncia foi confirmada pela moderação."
    }

    results =
      run_concurrently(repo, [
        fn ->
          Reviews.resolve_report(
            moderator_scope,
            Map.put(base_request, :idempotency_key, "resolve-report-race-001")
          )
        end,
        fn ->
          Reviews.resolve_report(
            moderator_scope,
            Map.put(base_request, :idempotency_key, "resolve-report-race-002")
          )
        end
      ])

    assert Enum.count(results, &match?({:ok, _result}, &1)) == 1

    assert Enum.count(
             results,
             &match?({:error, :invalid_review_report_transition}, &1)
           ) == 1

    assert %{rows: [["accepted", "hidden", 1, 1, 1, 2]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 (SELECT status FROM review_reports WHERE id = $1),
                 (SELECT status FROM reviews WHERE id = $2),
                 (SELECT count(*) FROM moderation_actions WHERE review_report_id = $1),
                 (SELECT count(*) FROM domain_events
                    WHERE event_type = 'review.report.accepted' AND aggregate_id = $1),
                 (SELECT count(*) FROM domain_events
                    WHERE event_type = 'review.hidden' AND aggregate_id = $2),
                 (SELECT count(*) FROM tenant_idempotency_keys
                    WHERE scope = 'reviews.resolve_report')
               """,
               [report["id"], fixture.submission.review.id]
             )
  end

  defp review_id(results) do
    results
    |> Enum.find_value(fn
      {:ok, submission} -> submission.review.id
      _other -> nil
    end)
  end
end
