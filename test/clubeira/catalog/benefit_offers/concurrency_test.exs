defmodule Clubeira.Catalog.BenefitOfferConcurrencyTest do
  use Clubeira.ConcurrencyCase, async: false

  alias Clubeira.Catalog
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.ReviewsFixtures

  test "concurrent retries publish one benefit offer and replay the committed response", %{
    repo: repo
  } do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    before = benefit_offer_counts(fixture)
    request = benefit_offer_request("retry", "benefit-offer-concurrent-retry", fixture)

    assert [{:ok, first}, {:ok, second}] =
             run_concurrently(repo, [
               fn -> Catalog.publish_benefit_offer(scope, fixture.ids.place, request) end,
               fn -> Catalog.publish_benefit_offer(scope, fixture.ids.place, request) end
             ])

    assert first == second

    assert count_deltas(before, benefit_offer_counts(fixture)) == %{
             audits: 1,
             domain_events: 1,
             idempotency_keys: 1,
             offer_places: 1,
             offers: 1,
             outbox_messages: 1,
             versions: 1
           }
  end

  test "concurrent distinct keys for one benefit code commit one offer and one stable conflict",
       %{
         repo: repo
       } do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    before = benefit_offer_counts(fixture)

    results =
      run_concurrently(repo, [
        fn ->
          Catalog.publish_benefit_offer(
            scope,
            fixture.ids.place,
            benefit_offer_request("shared", "benefit-offer-concurrent-first", fixture)
          )
        end,
        fn ->
          Catalog.publish_benefit_offer(
            scope,
            fixture.ids.place,
            benefit_offer_request("shared", "benefit-offer-concurrent-second", fixture)
          )
        end
      ])

    assert Enum.count(results, &match?({:ok, _result}, &1)) == 1
    assert Enum.count(results, &match?({:error, :offer_code_taken}, &1)) == 1

    assert count_deltas(before, benefit_offer_counts(fixture)) == %{
             audits: 2,
             domain_events: 1,
             idempotency_keys: 2,
             offer_places: 1,
             offers: 1,
             outbox_messages: 1,
             versions: 1
           }
  end

  defp benefit_offer_request(suffix, idempotency_key, fixture) do
    %{
      offer: %{
        code: "beneficio-concorrente-#{suffix}",
        name: "Benefício concorrente #{suffix}",
        benefit_kind: "complimentary_item"
      },
      version: %{
        title: "Cortesia concorrente #{suffix}",
        description: "Benefício publicado sob concorrência real.",
        terms: "Um uso por ciclo.",
        redemption_instructions: "Apresente o voucher no caixa.",
        effective_during: %{
          starts_at: DateTime.add(fixture.now, -60),
          ends_at: nil
        }
      },
      idempotency_key: idempotency_key
    }
  end

  defp benefit_offer_counts(fixture) do
    %{rows: [[offers, versions, offer_places, audits, events, outbox, idempotency_keys]]} =
      RedemptionsFixtures.scoped_query!(fixture, """
      SELECT
        (SELECT count(*) FROM benefit_offers),
        (SELECT count(*) FROM benefit_offer_versions),
        (SELECT count(*) FROM benefit_offer_version_places),
        (SELECT count(*) FROM tenant_audit_events
           WHERE action IN (
             'benefit_offer.published',
             'benefit_offer.publication_rejected'
           )),
        (SELECT count(*) FROM domain_events
           WHERE aggregate_type = 'benefit_offer'),
        (SELECT count(*) FROM outbox_messages
           WHERE topic = 'catalog.benefit_offers.published'),
        (SELECT count(*) FROM tenant_idempotency_keys
           WHERE scope = 'catalog.publish_benefit_offer')
      """)

    %{
      offers: offers,
      versions: versions,
      offer_places: offer_places,
      audits: audits,
      domain_events: events,
      outbox_messages: outbox,
      idempotency_keys: idempotency_keys
    }
  end
end
