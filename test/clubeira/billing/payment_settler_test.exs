defmodule Clubeira.Billing.PaymentSettlerTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Billing
  alias Clubeira.BillingFixtures
  alias Clubeira.Repo
  alias Clubeira.Subscriptions

  test "settles a verified capture and atomically materializes the first benefit cycle" do
    fixture = BillingFixtures.create!()
    assert {:ok, order} = place_order(fixture)
    settlement = BillingFixtures.settled_payment(fixture, order)

    assert {:ok, contract} = Billing.settle_payment(fixture.service_scope, settlement)
    assert contract.purchaser_user_id == fixture.user.id
    assert contract.status == "active"
    assert DateTime.after?(contract.starts_at, fixture.captured_at)
    assert DateTime.after?(contract.starts_at, order.placed_at)

    assert {:ok,
            %{
              rows: [
                [
                  "paid",
                  "succeeded",
                  "captured",
                  true,
                  1,
                  1,
                  2,
                  2,
                  1,
                  4,
                  4,
                  3,
                  "completed"
                ]
              ]
            }} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               {:ok,
                repo.query!(
                  """
                  SELECT
                    orders.status,
                    intents.status,
                    payments.status,
                    events.processed_at IS NOT NULL AND events.processing_error IS NULL,
                    (SELECT count(*) FROM benefit_cycles),
                    (SELECT count(*) FROM cycle_entitlement_subjects),
                    (SELECT count(*) FROM entitlement_allocations),
                    (SELECT count(*) FROM entitlement_ledger_entries WHERE entry_kind = 'initial_grant'),
                    (SELECT count(*) FROM contract_events WHERE event_type = 'activated'),
                    (SELECT count(*) FROM domain_events),
                    (SELECT count(*) FROM outbox_messages),
                    (SELECT count(*) FROM tenant_audit_events),
                    idempotency.status
                  FROM orders
                  JOIN payment_intents AS intents ON intents.order_id = orders.id
                  JOIN payments ON payments.payment_intent_id = intents.id
                  JOIN payment_provider_events AS events
                    ON events.external_event_id = $2
                  JOIN tenant_idempotency_keys AS idempotency
                    ON idempotency.resource_id = $3
                  WHERE orders.id = $1
                  """,
                  [
                    Ecto.UUID.dump!(order.id),
                    fixture.external_event_id,
                    Ecto.UUID.dump!(contract.id)
                  ]
                )}
             end)

    assert {:ok, subscriptions} = Subscriptions.list_for_account(fixture.account_scope)
    assert Enum.map(subscriptions, & &1.id) == [contract.id]

    assert {:ok, wallet} =
             Subscriptions.list_wallet(fixture.account_scope, fixture.polo_route.slug)

    assert length(wallet.vouchers) == 2

    assert Enum.sort(Enum.map(wallet.vouchers, & &1.allocation_kind)) == [
             "per_place",
             "shared_scope"
           ]
  end

  test "replays the same provider event without duplicating financial or entitlement records" do
    fixture = BillingFixtures.create!()
    assert {:ok, order} = place_order(fixture)
    settlement = BillingFixtures.settled_payment(fixture, order)

    assert {:ok, first} = Billing.settle_payment(fixture.service_scope, settlement)
    assert {:ok, replayed} = Billing.settle_payment(fixture.service_scope, settlement)
    assert replayed.id == first.id

    assert {:ok, %{rows: [[1, 1, 1, 1, 2]]}} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               {:ok,
                repo.query!("""
                SELECT
                  (SELECT count(*) FROM payment_provider_events),
                  (SELECT count(*) FROM payment_intents),
                  (SELECT count(*) FROM payments),
                  (SELECT count(*) FROM access_contracts),
                  (SELECT count(*) FROM entitlement_allocations)
                """)}
             end)
  end

  test "treats equivalent decimal representations as the same provider delivery" do
    fixture = BillingFixtures.create!()
    assert {:ok, order} = place_order(fixture)
    settlement = BillingFixtures.settled_payment(fixture, order)

    assert {:ok, first} = Billing.settle_payment(fixture.service_scope, settlement)

    assert {:ok, replayed} =
             Billing.settle_payment(
               fixture.service_scope,
               Map.put(
                 settlement,
                 :amount,
                 order.total_amount |> Decimal.normalize() |> Decimal.to_string(:normal)
               )
             )

    assert replayed.id == first.id
  end

  test "persists a rejected provider event without marking the order paid" do
    fixture = BillingFixtures.create!()
    assert {:ok, order} = place_order(fixture)

    settlement =
      BillingFixtures.settled_payment(fixture, order, amount: Decimal.new("1.00"))

    assert {:error, :payment_amount_mismatch} =
             Billing.settle_payment(fixture.service_scope, settlement)

    assert {:error, :payment_amount_mismatch} =
             Billing.settle_payment(fixture.service_scope, settlement)

    assert {:ok, %{rows: [["awaiting_payment", "payment_amount_mismatch", 0, "failed"]]}} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               {:ok,
                repo.query!(
                  """
                  SELECT
                    orders.status,
                    events.processing_error,
                    (SELECT count(*) FROM access_contracts),
                    idempotency.status
                  FROM orders
                  JOIN payment_provider_events AS events
                    ON events.external_event_id = $2
                  JOIN tenant_idempotency_keys AS idempotency
                    ON idempotency.resource_id = events.id
                  WHERE orders.id = $1
                  """,
                  [Ecto.UUID.dump!(order.id), fixture.external_event_id]
                )}
             end)
  end

  test "does not write a capture when subscription provisioning is invalid" do
    fixture = BillingFixtures.create!()
    assert {:ok, order} = place_order(fixture)

    assert {:ok, {1, nil}} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               result =
                 repo.update_all(
                   from(item in Clubeira.Subscriptions.BenefitPackageItem,
                     where: item.id == ^hd(fixture.package_items).id
                   ),
                   set: [subject_policy: "per_beneficiary"]
                 )

               {:ok, result}
             end)

    settlement = BillingFixtures.settled_payment(fixture, order)

    assert {:error, :unsupported_subject_policy} =
             Billing.settle_payment(fixture.service_scope, settlement)

    assert {:ok, %{rows: [["awaiting_payment", 0, 0, 0, "unsupported_subject_policy"]]}} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               {:ok,
                repo.query!(
                  """
                  SELECT
                    orders.status,
                    (SELECT count(*) FROM payment_intents),
                    (SELECT count(*) FROM payments),
                    (SELECT count(*) FROM access_contracts),
                    events.processing_error
                  FROM orders
                  JOIN payment_provider_events AS events
                    ON events.external_event_id = $2
                  WHERE orders.id = $1
                  """,
                  [Ecto.UUID.dump!(order.id), fixture.external_event_id]
                )}
             end)
  end

  test "rejects a provider timestamp outside the accepted clock skew" do
    fixture = BillingFixtures.create!()
    assert {:ok, order} = place_order(fixture)

    settlement =
      BillingFixtures.settled_payment(fixture, order,
        occurred_at: DateTime.add(order.placed_at, 3_600, :second)
      )

    assert {:error, :payment_timestamp_out_of_bounds} =
             Billing.settle_payment(fixture.service_scope, settlement)

    assert {:ok, %{rows: [["awaiting_payment", "payment_timestamp_out_of_bounds", 0, 0]]}} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               {:ok,
                repo.query!(
                  """
                  SELECT
                    orders.status,
                    events.processing_error,
                    (SELECT count(*) FROM payment_intents),
                    (SELECT count(*) FROM payments)
                  FROM orders
                  JOIN payment_provider_events AS events
                    ON events.external_event_id = $2
                  WHERE orders.id = $1
                  """,
                  [Ecto.UUID.dump!(order.id), fixture.external_event_id]
                )}
             end)
  end

  test "a wrong polo route cannot consume the provider event" do
    fixture = BillingFixtures.create!()
    other_polo = BillingFixtures.create!()
    assert {:ok, order} = place_order(fixture)
    settlement = BillingFixtures.settled_payment(fixture, order)

    assert {:ok, _assignment} =
             Repo.transact_in_polo(other_polo.service_scope, fn _repo ->
               {:ok,
                insert(:polo_merchant_account,
                  polo: other_polo.polo,
                  payment_provider: fixture.provider,
                  merchant_account: fixture.merchant_account
                )}
             end)

    assert {:error, :order_not_found} =
             Billing.settle_payment(other_polo.service_scope, settlement)

    assert {:ok, %{rows: [[0]]}} =
             Repo.transact_in_polo(other_polo.service_scope, fn repo ->
               {:ok,
                repo.query!(
                  "SELECT count(*) FROM payment_provider_events WHERE external_event_id = $1",
                  [fixture.external_event_id]
                )}
             end)

    assert {:ok, contract} = Billing.settle_payment(fixture.service_scope, settlement)
    assert contract.purchaser_user_id == fixture.user.id
  end

  test "records a reused provider reference without partially capturing another order" do
    fixture = BillingFixtures.create!()
    assert {:ok, first_order} = place_order(fixture)

    assert {:ok, second_order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture,
                 idempotency_key: "checkout-#{Ecto.UUID.generate()}"
               )
             )

    first_settlement = BillingFixtures.settled_payment(fixture, first_order)
    assert {:ok, _contract} = Billing.settle_payment(fixture.service_scope, first_settlement)

    second_settlement =
      BillingFixtures.settled_payment(fixture, second_order,
        external_event_id: "evt-#{Ecto.UUID.generate()}"
      )

    assert {:error, :payment_reference_conflict} =
             Billing.settle_payment(fixture.service_scope, second_settlement)

    assert {:ok, %{rows: [["awaiting_payment", 1, 1, 1, "payment_reference_conflict"]]}} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               {:ok,
                repo.query!(
                  """
                  SELECT
                    orders.status,
                    (SELECT count(*) FROM payment_intents),
                    (SELECT count(*) FROM payments),
                    (SELECT count(*) FROM access_contracts),
                    events.processing_error
                  FROM orders
                  JOIN payment_provider_events AS events
                    ON events.external_event_id = $2
                  WHERE orders.id = $1
                  """,
                  [
                    Ecto.UUID.dump!(second_order.id),
                    second_settlement.external_event_id
                  ]
                )}
             end)
  end

  test "is not callable with a member scope" do
    fixture = BillingFixtures.create!()
    assert {:ok, order} = place_order(fixture)

    assert {:error, :service_scope_required} =
             Billing.settle_payment(
               fixture.member_scope,
               BillingFixtures.settled_payment(fixture, order)
             )
  end

  defp place_order(fixture) do
    Billing.place_order(fixture.member_scope, BillingFixtures.checkout_request(fixture))
  end
end
