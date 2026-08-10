defmodule Clubeira.Billing.ConcurrencyTest do
  use Clubeira.ConcurrencyCase, async: false

  alias Clubeira.Billing
  alias Clubeira.BillingFixtures
  alias Clubeira.Repo

  test "serializes concurrent retries of the same checkout", %{repo: repo} do
    fixture = BillingFixtures.create!()
    request = BillingFixtures.checkout_request(fixture)

    assert [{:ok, first}, {:ok, second}] =
             run_concurrently(repo, [
               fn -> Billing.place_order(fixture.member_scope, request) end,
               fn -> Billing.place_order(fixture.member_scope, request) end
             ])

    assert first.id == second.id

    assert %{rows: [[1, 1, 1]]} =
             scoped_query(
               fixture.service_scope,
               """
               SELECT
                 (SELECT count(*) FROM orders WHERE polo_id = $1),
                 (SELECT count(*) FROM order_items WHERE polo_id = $1),
                 (SELECT count(*) FROM tenant_idempotency_keys
                    WHERE polo_id = $1 AND scope = 'billing.place_order')
               """,
               [fixture.polo.id]
             )
  end

  test "replays one complete subscription for concurrent delivery of one provider event", %{
    repo: repo
  } do
    fixture = BillingFixtures.create!()
    assert {:ok, order} = place_order(fixture)
    settlement = BillingFixtures.settled_payment(fixture, order)

    assert [{:ok, first}, {:ok, second}] =
             run_concurrently(repo, [
               fn -> Billing.settle_payment(fixture.service_scope, settlement) end,
               fn -> Billing.settle_payment(fixture.service_scope, settlement) end
             ])

    assert first.id == second.id
    assert %{rows: [[1, 1, 1, 1, 1, 2]]} = settlement_counts(fixture)
  end

  test "accepts only one of two competing captures for the same order", %{repo: repo} do
    fixture = BillingFixtures.create!()
    assert {:ok, order} = place_order(fixture)
    first = BillingFixtures.settled_payment(fixture, order)

    second =
      BillingFixtures.settled_payment(fixture, order,
        external_event_id: "evt-#{Ecto.UUID.generate()}",
        provider_reference: "pay-#{Ecto.UUID.generate()}"
      )

    results =
      run_concurrently(repo, [
        fn -> Billing.settle_payment(fixture.service_scope, first) end,
        fn -> Billing.settle_payment(fixture.service_scope, second) end
      ])

    assert Enum.count(results, &match?({:ok, _contract}, &1)) == 1
    assert Enum.count(results, &match?({:error, :order_already_paid}, &1)) == 1

    assert %{rows: [[2, 1, 1, 1, 1, 2]]} = settlement_counts(fixture)

    assert %{rows: [[1, 1]]} =
             scoped_query(
               fixture.service_scope,
               """
               SELECT
                 count(*) FILTER (WHERE processing_error IS NULL),
                 count(*) FILTER (WHERE processing_error = 'order_already_paid')
               FROM payment_provider_events
               WHERE polo_id = $1
               """,
               [fixture.polo.id]
             )
  end

  defp place_order(fixture) do
    Billing.place_order(fixture.member_scope, BillingFixtures.checkout_request(fixture))
  end

  defp settlement_counts(fixture) do
    scoped_query(
      fixture.service_scope,
      """
      SELECT
        (SELECT count(*) FROM payment_provider_events WHERE polo_id = $1),
        (SELECT count(*) FROM payment_intents WHERE polo_id = $1),
        (SELECT count(*) FROM payments WHERE polo_id = $1),
        (SELECT count(*) FROM access_contracts WHERE polo_id = $1),
        (SELECT count(*) FROM benefit_cycles WHERE polo_id = $1),
        (SELECT count(*) FROM entitlement_allocations WHERE polo_id = $1)
      """,
      [fixture.polo.id]
    )
  end

  defp scoped_query(scope, sql, parameters) do
    {:ok, result} =
      Repo.transact_in_polo(scope, fn repo ->
        {:ok, repo.query!(sql, Enum.map(parameters, &Ecto.UUID.dump!/1))}
      end)

    result
  end
end
