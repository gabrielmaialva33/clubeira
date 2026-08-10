defmodule Clubeira.Subscriptions.ProductOfferingConcurrencyTest do
  use Clubeira.ConcurrencyCase, async: false

  alias Clubeira.RedemptionsFixtures
  alias Clubeira.ReviewsFixtures
  alias Clubeira.Subscriptions

  test "concurrent retries publish one complete product offering and replay its response", %{
    repo: repo
  } do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    before = product_offering_counts(fixture)
    request = product_offering_request("product-offering-concurrent-retry", fixture)

    assert [{:ok, first}, {:ok, second}] =
             run_concurrently(repo, [
               fn -> Subscriptions.publish_product_offering(scope, request) end,
               fn -> Subscriptions.publish_product_offering(scope, request) end
             ])

    assert first == second

    assert count_deltas(before, product_offering_counts(fixture)) == %{
             access_product_versions: 1,
             access_products: 1,
             audits: 1,
             benefit_package_items: 1,
             benefit_package_versions: 1,
             benefit_packages: 1,
             domain_events: 1,
             entitlement_scope_places: 1,
             entitlement_scopes: 1,
             idempotency_keys: 1,
             offering_prices: 1,
             outbox_messages: 1,
             package_assignments: 1,
             product_offering_versions: 1,
             product_offerings: 1
           }
  end

  test "concurrent distinct keys for one product code commit one graph and one conflict", %{
    repo: repo
  } do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    before = product_offering_counts(fixture)

    results =
      run_concurrently(repo, [
        fn ->
          Subscriptions.publish_product_offering(
            scope,
            product_offering_request("product-offering-concurrent-first", fixture)
          )
        end,
        fn ->
          Subscriptions.publish_product_offering(
            scope,
            product_offering_request("product-offering-concurrent-second", fixture)
          )
        end
      ])

    assert Enum.count(results, &match?({:ok, _result}, &1)) == 1
    assert Enum.count(results, &match?({:error, :product_offering_code_taken}, &1)) == 1

    assert count_deltas(before, product_offering_counts(fixture)) == %{
             access_product_versions: 1,
             access_products: 1,
             audits: 2,
             benefit_package_items: 1,
             benefit_package_versions: 1,
             benefit_packages: 1,
             domain_events: 1,
             entitlement_scope_places: 1,
             entitlement_scopes: 1,
             idempotency_keys: 2,
             offering_prices: 1,
             outbox_messages: 1,
             package_assignments: 1,
             product_offering_versions: 1,
             product_offerings: 1
           }
  end

  test "concurrent retries pause one product offering and replay the committed transition", %{
    repo: repo
  } do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    before = product_offering_lifecycle_counts(fixture)

    request = %{
      action: "pause",
      reason: "Interrupção comercial concorrente",
      idempotency_key: "product-offering-concurrent-pause-retry"
    }

    assert [{:ok, first}, {:ok, second}] =
             run_concurrently(repo, [
               fn ->
                 Subscriptions.transition_product_offering(
                   scope,
                   fixture.ids.product_offering,
                   request
                 )
               end,
               fn ->
                 Subscriptions.transition_product_offering(
                   scope,
                   fixture.ids.product_offering,
                   request
                 )
               end
             ])

    assert first == second
    assert first["status"] == "paused"
    assert first["revision"] == 2

    assert count_deltas(before, product_offering_lifecycle_counts(fixture)) == %{
             audits: 1,
             domain_events: 1,
             idempotency_keys: 1,
             outbox_messages: 1
           }
  end

  test "concurrent distinct pause keys serialize one transition and one stable rejection", %{
    repo: repo
  } do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    before = product_offering_lifecycle_counts(fixture)

    results =
      run_concurrently(repo, [
        fn ->
          Subscriptions.transition_product_offering(
            scope,
            fixture.ids.product_offering,
            %{
              action: "pause",
              reason: "Primeira solicitação concorrente",
              idempotency_key: "product-offering-concurrent-pause-first"
            }
          )
        end,
        fn ->
          Subscriptions.transition_product_offering(
            scope,
            fixture.ids.product_offering,
            %{
              action: "pause",
              reason: "Segunda solicitação concorrente",
              idempotency_key: "product-offering-concurrent-pause-second"
            }
          )
        end
      ])

    assert Enum.count(results, &match?({:ok, %{"status" => "paused", "revision" => 2}}, &1)) ==
             1

    assert Enum.count(results, &match?({:error, :invalid_product_offering_transition}, &1)) ==
             1

    assert count_deltas(before, product_offering_lifecycle_counts(fixture)) == %{
             audits: 2,
             domain_events: 1,
             idempotency_keys: 2,
             outbox_messages: 1
           }

    assert %{rows: [["paused", 2]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT status, revision
               FROM product_offerings
               WHERE id = $1
               """,
               [fixture.ids.product_offering]
             )
  end

  defp product_offering_request(idempotency_key, fixture) do
    %{
      offering: %{
        code: "produto-concorrente",
        name: "Produto concorrente",
        description: "Configuração comercial publicada sob concorrência real.",
        cycle: %{policy: "calendar", interval_unit: "month", interval_count: 1},
        effective_during: %{
          starts_at: DateTime.add(fixture.now, -60),
          ends_at: nil
        }
      },
      price: %{currency: "BRL", amount: "49.90"},
      benefits: [
        %{
          benefit_offer_version_id: fixture.ids.benefit_offer_version,
          allowance_per_cycle: 1,
          consumption_unit: "per_place"
        }
      ],
      idempotency_key: idempotency_key
    }
  end

  defp product_offering_counts(fixture) do
    %{
      rows: [
        [
          access_products,
          access_product_versions,
          product_offerings,
          product_offering_versions,
          offering_prices,
          benefit_packages,
          benefit_package_versions,
          entitlement_scopes,
          entitlement_scope_places,
          benefit_package_items,
          package_assignments,
          audits,
          events,
          outbox,
          idempotency_keys
        ]
      ]
    } =
      RedemptionsFixtures.scoped_query!(fixture, """
      SELECT
        (SELECT count(*) FROM access_products),
        (SELECT count(*) FROM access_product_versions),
        (SELECT count(*) FROM product_offerings),
        (SELECT count(*) FROM product_offering_versions),
        (SELECT count(*) FROM offering_prices),
        (SELECT count(*) FROM benefit_packages),
        (SELECT count(*) FROM benefit_package_versions),
        (SELECT count(*) FROM entitlement_scopes),
        (SELECT count(*) FROM entitlement_scope_places),
        (SELECT count(*) FROM benefit_package_items),
        (SELECT count(*) FROM product_offering_package_assignments),
        (SELECT count(*) FROM tenant_audit_events
           WHERE action IN (
             'product_offering.published',
             'product_offering.publication_rejected'
           )),
        (SELECT count(*) FROM domain_events
           WHERE aggregate_type = 'product_offering'),
        (SELECT count(*) FROM outbox_messages
           WHERE topic = 'subscriptions.product_offerings.published'),
        (SELECT count(*) FROM tenant_idempotency_keys
           WHERE scope = 'subscriptions.publish_product_offering')
      """)

    %{
      access_products: access_products,
      access_product_versions: access_product_versions,
      product_offerings: product_offerings,
      product_offering_versions: product_offering_versions,
      offering_prices: offering_prices,
      benefit_packages: benefit_packages,
      benefit_package_versions: benefit_package_versions,
      entitlement_scopes: entitlement_scopes,
      entitlement_scope_places: entitlement_scope_places,
      benefit_package_items: benefit_package_items,
      package_assignments: package_assignments,
      audits: audits,
      domain_events: events,
      outbox_messages: outbox,
      idempotency_keys: idempotency_keys
    }
  end

  defp product_offering_lifecycle_counts(fixture) do
    %{rows: [[audits, events, outbox, idempotency_keys]]} =
      RedemptionsFixtures.scoped_query!(fixture, """
      SELECT
        (SELECT count(*) FROM tenant_audit_events
           WHERE action IN (
             'product_offering.paused',
             'product_offering.reactivated',
             'product_offering.retired',
             'product_offering.transition_rejected'
           )),
        (SELECT count(*) FROM domain_events
           WHERE event_type IN (
             'product_offering.paused',
             'product_offering.reactivated',
             'product_offering.retired'
           )),
        (SELECT count(*) FROM outbox_messages
           WHERE topic IN (
             'subscriptions.product_offerings.paused',
             'subscriptions.product_offerings.reactivated',
             'subscriptions.product_offerings.retired'
           )),
        (SELECT count(*) FROM tenant_idempotency_keys
           WHERE scope = 'subscriptions.transition_product_offering')
      """)

    %{
      audits: audits,
      domain_events: events,
      outbox_messages: outbox,
      idempotency_keys: idempotency_keys
    }
  end
end
