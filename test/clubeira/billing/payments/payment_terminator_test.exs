defmodule Clubeira.Billing.PaymentTerminatorTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Billing
  alias Clubeira.Billing.PaymentTerminator
  alias Clubeira.BillingFixtures
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  test "terminates a live payment intent and replays the provider event atomically" do
    fixture = BillingFixtures.create!()
    assert {:ok, order} = place_order(fixture)
    intent = insert_intent!(fixture, order)
    payment = terminal_payment(fixture, order, status: "expired")
    service_scope = Scope.new!(fixture.polo.id)

    assert {:ok, terminated} =
             PaymentTerminator.terminate(
               service_scope,
               fixture.provider,
               fixture.merchant_account,
               fixture.external_event_id,
               payment
             )

    assert terminated.id == intent.id
    assert terminated.status == "expired"
    assert terminated.provider_reference == fixture.provider_reference
    assert terminated.next_action == %{}

    assert {:ok, replayed} =
             PaymentTerminator.terminate(
               service_scope,
               fixture.provider,
               fixture.merchant_account,
               fixture.external_event_id,
               payment
             )

    assert replayed.id == intent.id

    assert {:ok, %{rows: [[1, 1, 1, 1, "completed", true]]}} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               {:ok,
                repo.query!("""
                SELECT
                  (SELECT count(*) FROM payment_provider_events),
                  (SELECT count(*) FROM domain_events
                   WHERE event_type = 'payment_intent.expired'),
                  (SELECT count(*) FROM outbox_messages
                   WHERE topic = 'billing.payment_intents.expired'),
                  (SELECT count(*) FROM tenant_audit_events
                   WHERE action = 'payment_intent.expired'),
                  (SELECT status FROM tenant_idempotency_keys
                   WHERE scope = 'billing.terminate_payment'),
                  (SELECT processed_at IS NOT NULL AND processing_error IS NULL
                   FROM payment_provider_events)
                """)}
             end)
  end

  test "reconciles a second provider delivery without duplicating termination facts" do
    fixture = BillingFixtures.create!()
    assert {:ok, order} = place_order(fixture)
    _intent = insert_intent!(fixture, order)
    payment = terminal_payment(fixture, order, status: "cancelled")

    assert {:ok, first} = terminate(fixture, fixture.external_event_id, payment)
    assert {:ok, reconciled} = terminate(fixture, "evt-#{uuid7()}", payment)
    assert reconciled.id == first.id

    assert {:ok, %{rows: [[2, 1, 1, 1, 2]]}} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               {:ok,
                repo.query!("""
                SELECT
                  (SELECT count(*) FROM payment_provider_events),
                  (SELECT count(*) FROM domain_events
                   WHERE event_type = 'payment_intent.cancelled'),
                  (SELECT count(*) FROM outbox_messages
                   WHERE topic = 'billing.payment_intents.cancelled'),
                  (SELECT count(*) FROM tenant_audit_events
                   WHERE action = 'payment_intent.cancelled'),
                  (SELECT count(*) FROM tenant_idempotency_keys
                   WHERE scope = 'billing.terminate_payment' AND status = 'completed')
                """)}
             end)
  end

  test "persists and replays a rejected provider event when no intent exists" do
    fixture = BillingFixtures.create!()
    assert {:ok, order} = place_order(fixture)
    payment = terminal_payment(fixture, order, status: "failed")

    assert {:error, :payment_intent_not_found} =
             terminate(fixture, fixture.external_event_id, payment)

    assert {:error, :payment_intent_not_found} =
             terminate(fixture, fixture.external_event_id, payment)

    assert {:ok, %{rows: [["payment_intent_not_found", true, "failed"]]}} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               {:ok,
                repo.query!(
                  """
                  SELECT
                    events.processing_error,
                    events.processed_at IS NOT NULL,
                    idempotency.status
                  FROM payment_provider_events AS events
                  JOIN tenant_idempotency_keys AS idempotency
                    ON idempotency.resource_id = events.id
                  WHERE events.external_event_id = $1
                  """,
                  [fixture.external_event_id]
                )}
             end)
  end

  test "persists a mismatch without changing the live intent" do
    fixture = BillingFixtures.create!()
    assert {:ok, order} = place_order(fixture)
    intent = insert_intent!(fixture, order)

    payment =
      terminal_payment(fixture, order,
        status: "expired",
        amount: Decimal.add(order.total_amount, Decimal.new("1.00"))
      )

    assert {:error, :payment_intent_mismatch} =
             terminate(fixture, fixture.external_event_id, payment)

    assert {:ok, %{rows: [["created", nil, "payment_intent_mismatch", "failed"]]}} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               {:ok,
                repo.query!(
                  """
                  SELECT
                    intents.status,
                    intents.provider_reference,
                    events.processing_error,
                    idempotency.status
                  FROM payment_intents AS intents
                  JOIN payment_provider_events AS events
                    ON events.external_event_id = $2
                  JOIN tenant_idempotency_keys AS idempotency
                    ON idempotency.resource_id = events.id
                  WHERE intents.id = $1
                  """,
                  [Ecto.UUID.dump!(intent.id), fixture.external_event_id]
                )}
             end)
  end

  test "rejects a changed replay before processing another provider event" do
    fixture = BillingFixtures.create!()
    assert {:ok, order} = place_order(fixture)
    payment = terminal_payment(fixture, order, status: "failed")

    assert {:error, :payment_intent_not_found} =
             terminate(fixture, fixture.external_event_id, payment)

    changed_payment = put_in(payment.payload["delivery"], "changed")

    assert {:error, :idempotency_conflict} =
             terminate(fixture, fixture.external_event_id, changed_payment)

    assert {:ok, %{rows: [[1]]}} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               {:ok, repo.query!("SELECT count(*) FROM payment_provider_events")}
             end)
  end

  test "distinguishes a missing order from one that is no longer payable" do
    fixture = BillingFixtures.create!()
    assert {:ok, order} = place_order(fixture)

    missing_order_payment =
      terminal_payment(fixture, order, order_id: uuid7(), status: "expired")

    assert {:error, :order_not_found} =
             terminate(fixture, "evt-#{uuid7()}", missing_order_payment)

    assert {:ok, {1, nil}} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               {:ok,
                repo.update_all(
                  from(stored_order in Clubeira.Subscriptions.Order,
                    where: stored_order.id == ^order.id
                  ),
                  set: [status: "paid"]
                )}
             end)

    assert {:error, :order_not_payable} =
             terminate(fixture, "evt-#{uuid7()}", terminal_payment(fixture, order))
  end

  test "rejects an event identity already persisted outside this command" do
    fixture = BillingFixtures.create!()
    assert {:ok, order} = place_order(fixture)
    _intent = insert_intent!(fixture, order)

    assert {:ok, _event} =
             Repo.transact_in_polo(fixture.service_scope, fn _repo ->
               {:ok,
                insert(:payment_provider_event,
                  payment_provider: fixture.provider,
                  merchant_account: fixture.merchant_account,
                  polo: fixture.polo,
                  external_event_id: fixture.external_event_id
                )}
             end)

    assert {:error, :provider_event_already_received} =
             terminate(fixture, fixture.external_event_id, terminal_payment(fixture, order))
  end

  test "rejects a provider reference already attached to another intent" do
    fixture = BillingFixtures.create!()
    assert {:ok, first_order} = place_order(fixture)

    assert {:ok, second_order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture,
                 idempotency_key: "checkout-#{uuid7()}"
               )
             )

    _first_intent =
      insert_intent!(fixture, first_order,
        status: "expired",
        provider_reference: fixture.provider_reference
      )

    second_intent = insert_intent!(fixture, second_order)

    assert {:error, :payment_reference_conflict} =
             terminate(
               fixture,
               fixture.external_event_id,
               terminal_payment(fixture, second_order)
             )

    assert {:ok, %{rows: [["created", nil, "payment_reference_conflict"]]}} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               {:ok,
                repo.query!(
                  """
                  SELECT intents.status, intents.provider_reference, events.processing_error
                  FROM payment_intents AS intents
                  JOIN payment_provider_events AS events ON events.external_event_id = $2
                  WHERE intents.id = $1
                  """,
                  [Ecto.UUID.dump!(second_intent.id), fixture.external_event_id]
                )}
             end)
  end

  test "rejects malformed calls before opening a tenant transaction" do
    fixture = BillingFixtures.create!()
    assert {:ok, order} = place_order(fixture)
    payment = terminal_payment(fixture, order)

    assert {:error, :invalid_terminal_payment} =
             PaymentTerminator.terminate(
               fixture.member_scope,
               fixture.provider,
               fixture.merchant_account,
               fixture.external_event_id,
               payment
             )

    assert {:error, :invalid_terminal_payment} =
             terminate(fixture, fixture.external_event_id, %{payment | status: "succeeded"})

    assert {:error, :invalid_terminal_payment} =
             PaymentTerminator.terminate(
               fixture.service_scope,
               fixture.provider,
               fixture.merchant_account,
               nil,
               payment
             )
  end

  defp insert_intent!(fixture, order, overrides \\ []) do
    {:ok, intent} =
      Repo.transact_in_polo(fixture.service_scope, fn _repo ->
        attributes =
          [
            polo: fixture.polo,
            order: order,
            merchant_account: fixture.merchant_account,
            status: "created",
            provider_reference: nil,
            payment_method: "pix",
            amount: order.total_amount,
            currency: order.currency,
            next_action: %{"type" => "pix"}
          ]
          |> Keyword.merge(overrides)

        {:ok, insert(:payment_intent, attributes)}
      end)

    intent
  end

  defp place_order(fixture) do
    Billing.place_order(fixture.member_scope, BillingFixtures.checkout_request(fixture))
  end

  defp terminate(fixture, external_event_id, payment) do
    PaymentTerminator.terminate(
      fixture.service_scope,
      fixture.provider,
      fixture.merchant_account,
      external_event_id,
      payment
    )
  end

  defp terminal_payment(fixture, order, overrides \\ []) do
    overrides
    |> Map.new()
    |> then(
      &Map.merge(
        %{
          amount: order.total_amount,
          currency: order.currency,
          occurred_at: DateTime.utc_now(:microsecond),
          order_id: order.id,
          payload: %{"source" => "payment_terminator_test"},
          polo_id: fixture.polo.id,
          provider_reference: fixture.provider_reference,
          status: "expired"
        },
        &1
      )
    )
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
