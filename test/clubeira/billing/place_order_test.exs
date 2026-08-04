defmodule Clubeira.Billing.PlaceOrderTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Billing
  alias Clubeira.BillingFixtures
  alias Clubeira.Repo

  test "places one subscription order with authoritative server-side pricing and a durable trail" do
    fixture = BillingFixtures.create!()

    request =
      fixture
      |> BillingFixtures.checkout_request()
      |> Map.put(:amount, "0.01")
      |> Map.put(:currency, "USD")

    assert {:ok, order} = Billing.place_order(fixture.member_scope, request)
    assert order.purchaser_user_id == fixture.user.id
    assert order.status == "awaiting_payment"
    assert order.currency == fixture.price.currency
    assert Decimal.equal?(order.total_amount, fixture.price.amount)

    assert {:ok, %{rows: [[item_price_id, item_amount, 1, 1, 1, "completed"]]}} =
             Repo.transact_in_polo(fixture.member_scope, fn repo ->
               {:ok,
                repo.query!(
                  """
                  SELECT
                    item.offering_price_id,
                    item.total_amount,
                    (SELECT count(*) FROM domain_events WHERE event_type = 'order.placed'),
                    (SELECT count(*) FROM outbox_messages WHERE topic = 'billing.orders.placed'),
                    (SELECT count(*) FROM tenant_audit_events WHERE action = 'order.placed'),
                    idempotency.status
                  FROM order_items AS item
                  JOIN tenant_idempotency_keys AS idempotency
                    ON idempotency.resource_id = item.order_id
                  WHERE item.order_id = $1
                  """,
                  [Ecto.UUID.dump!(order.id)]
                )}
             end)

    assert Ecto.UUID.load!(item_price_id) == fixture.price.id
    assert Decimal.equal?(item_amount, fixture.price.amount)
  end

  test "replays the same checkout and rejects reuse of its key for another request" do
    fixture = BillingFixtures.create!()
    request = BillingFixtures.checkout_request(fixture)

    assert {:ok, first} = Billing.place_order(fixture.member_scope, request)
    assert {:ok, replayed} = Billing.place_order(fixture.member_scope, request)
    assert replayed.id == first.id

    conflicting = Map.put(request, :offering_price_id, Ecto.UUID.generate())

    assert {:error, :idempotency_conflict} =
             Billing.place_order(fixture.member_scope, conflicting)

    assert {:ok, %{rows: [[1, 1, 1]]}} =
             Repo.transact_in_polo(fixture.member_scope, fn repo ->
               {:ok,
                repo.query!("""
                SELECT
                  (SELECT count(*) FROM orders),
                  (SELECT count(*) FROM domain_events WHERE event_type = 'order.placed'),
                  (SELECT count(*) FROM outbox_messages WHERE topic = 'billing.orders.placed')
                """)}
             end)
  end

  test "requires an authenticated actor" do
    fixture = BillingFixtures.create!()

    assert {:error, :actor_required} =
             Billing.place_order(fixture.service_scope, BillingFixtures.checkout_request(fixture))
  end
end
