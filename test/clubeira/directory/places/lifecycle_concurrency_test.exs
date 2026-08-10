defmodule Clubeira.Directory.PlaceParticipationConcurrencyTest do
  use Clubeira.ConcurrencyCase, async: false

  alias Clubeira.Directory
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.ReviewsFixtures

  test "concurrent retries suspend one place participation and replay the committed transition",
       %{
         repo: repo
       } do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    before = place_participation_lifecycle_counts(fixture)

    request = %{
      action: "suspend",
      reason: "Isolamento concorrente da participação",
      idempotency_key: "place-participation-concurrent-suspension-retry"
    }

    assert [{:ok, first}, {:ok, second}] =
             run_concurrently(repo, [
               fn ->
                 Directory.transition_place_participation(scope, fixture.ids.place, request)
               end,
               fn ->
                 Directory.transition_place_participation(scope, fixture.ids.place, request)
               end
             ])

    assert first == second
    assert first["status"] == "suspended"
    assert first["revision"] == 2

    assert count_deltas(before, place_participation_lifecycle_counts(fixture)) == %{
             audits: 1,
             domain_events: 1,
             idempotency_keys: 1,
             outbox_messages: 1
           }
  end

  test "concurrent distinct suspension keys serialize one transition and one rejection", %{
    repo: repo
  } do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    before = place_participation_lifecycle_counts(fixture)

    results =
      run_concurrently(repo, [
        fn ->
          Directory.transition_place_participation(scope, fixture.ids.place, %{
            action: "suspend",
            reason: "Primeira suspensão concorrente",
            idempotency_key: "place-participation-concurrent-suspension-first"
          })
        end,
        fn ->
          Directory.transition_place_participation(scope, fixture.ids.place, %{
            action: "suspend",
            reason: "Segunda suspensão concorrente",
            idempotency_key: "place-participation-concurrent-suspension-second"
          })
        end
      ])

    assert Enum.count(results, &match?({:ok, %{"status" => "suspended", "revision" => 2}}, &1)) ==
             1

    assert Enum.count(
             results,
             &match?({:error, :invalid_place_participation_transition}, &1)
           ) == 1

    assert count_deltas(before, place_participation_lifecycle_counts(fixture)) == %{
             audits: 2,
             domain_events: 1,
             idempotency_keys: 2,
             outbox_messages: 1
           }

    assert %{rows: [["suspended", 2]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               "SELECT status, revision FROM polo_places WHERE id = $1",
               [fixture.ids.polo_place]
             )
  end

  test "concurrent distinct retirement keys leave one terminal participation", %{repo: repo} do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    before = place_participation_lifecycle_counts(fixture)

    results =
      run_concurrently(repo, [
        fn ->
          Directory.transition_place_participation(scope, fixture.ids.place, %{
            action: "retire",
            reason: "Primeiro encerramento concorrente",
            idempotency_key: "place-participation-concurrent-retirement-first"
          })
        end,
        fn ->
          Directory.transition_place_participation(scope, fixture.ids.place, %{
            action: "retire",
            reason: "Segundo encerramento concorrente",
            idempotency_key: "place-participation-concurrent-retirement-second"
          })
        end
      ])

    assert Enum.count(results, &match?({:ok, %{"status" => "retired", "revision" => 2}}, &1)) ==
             1

    assert Enum.count(
             results,
             &match?({:error, :invalid_place_participation_transition}, &1)
           ) == 1

    assert count_deltas(before, place_participation_lifecycle_counts(fixture)) == %{
             audits: 2,
             domain_events: 1,
             idempotency_keys: 2,
             outbox_messages: 1
           }

    assert %{rows: [["retired", 2, false]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT status, revision, participation_during @> statement_timestamp()
               FROM polo_places
               WHERE id = $1
               """,
               [fixture.ids.polo_place]
             )
  end

  defp place_participation_lifecycle_counts(fixture) do
    %{rows: [[audits, events, outbox, idempotency_keys]]} =
      RedemptionsFixtures.scoped_query!(fixture, """
      SELECT
        (SELECT count(*) FROM tenant_audit_events
           WHERE action IN (
             'polo_place.suspended',
             'polo_place.reactivated',
             'polo_place.retired',
             'polo_place.transition_rejected'
           )),
        (SELECT count(*) FROM domain_events
           WHERE event_type IN (
             'polo_place.suspended',
             'polo_place.reactivated',
             'polo_place.retired'
           )),
        (SELECT count(*) FROM outbox_messages
           WHERE topic IN (
             'directory.polo_places.suspended',
             'directory.polo_places.reactivated',
             'directory.polo_places.retired'
           )),
        (SELECT count(*) FROM tenant_idempotency_keys
           WHERE scope = 'directory.transition_place_participation')
      """)

    %{
      audits: audits,
      domain_events: events,
      outbox_messages: outbox,
      idempotency_keys: idempotency_keys
    }
  end
end
