defmodule Clubeira.Billing.RecurringInvoiceSettlerTest do
  use Clubeira.DataCase, async: false

  import Ecto.Query

  alias Clubeira.Billing
  alias Clubeira.Billing.BillingAgreement
  alias Clubeira.BillingFixtures
  alias Clubeira.Idempotency
  alias Clubeira.Repo
  alias Clubeira.Subscriptions.OrderItem
  alias Clubeira.Subscriptions.ProductOfferingVersion

  test "authenticated recurring invoices activate and renew one contract atomically" do
    fixture = BillingFixtures.create!()
    make_automatic!(fixture)

    fixture.provider
    |> Ecto.Changeset.change(code: "mercado_pago")
    |> Repo.update!()

    assert {:ok, order} =
             Billing.place_order(fixture.member_scope, BillingFixtures.checkout_request(fixture))

    agreement = insert_agreement!(fixture, order)
    first_evidence = recurring_evidence(fixture, agreement, "001", fixture.captured_at)

    assert {:ok, first} =
             Billing.reconcile_recurring_invoice(
               fixture.service_scope,
               fixture.provider,
               fixture.merchant_account,
               first_evidence
             )

    assert first.invoice.status == "paid"
    assert first.contract.billing_agreement_id == agreement.id
    assert first.contract.status == "active"

    assert {:ok, replayed} =
             Billing.reconcile_recurring_invoice(
               fixture.service_scope,
               fixture.provider,
               fixture.merchant_account,
               first_evidence
             )

    assert replayed.invoice.id == first.invoice.id
    assert replayed.contract.id == first.contract.id

    renewal_at = first.invoice.billing_period.upper
    second_evidence = recurring_evidence(fixture, agreement, "002", renewal_at)

    assert {:ok, renewed} =
             Billing.reconcile_recurring_invoice(
               fixture.service_scope,
               fixture.provider,
               fixture.merchant_account,
               second_evidence
             )

    assert renewed.contract.id == first.contract.id
    assert renewed.invoice.id != first.invoice.id
    assert renewed.invoice.billing_period.lower == first.invoice.billing_period.upper

    assert {:ok,
            %{
              rows: [
                [
                  "active",
                  2,
                  2,
                  2,
                  2,
                  1,
                  2,
                  2,
                  4,
                  1,
                  2,
                  true
                ]
              ]
            }} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               {:ok,
                repo.query!(
                  """
                  SELECT
                    agreements.status,
                    (SELECT count(*) FROM consumer_invoices),
                    (SELECT count(*) FROM payment_provider_events),
                    (SELECT count(*) FROM payment_intents),
                    (SELECT count(*) FROM payments),
                    (SELECT count(*) FROM access_contracts),
                    (SELECT count(*) FROM orders),
                    (SELECT count(*) FROM benefit_cycles),
                    (SELECT count(*) FROM entitlement_allocations),
                    (SELECT count(*) FROM contract_events WHERE event_type = 'renewed'),
                    (SELECT count(*) FROM domain_events
                     WHERE aggregate_type = 'consumer_invoice'),
                    contracts.billing_agreement_id = agreements.id
                  FROM billing_agreements AS agreements
                  JOIN access_contracts AS contracts
                    ON contracts.billing_agreement_id = agreements.id
                  WHERE agreements.id = $1
                  """,
                  [Ecto.UUID.dump!(agreement.id)]
                )}
             end)

    assert {:ok, _suspended} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               first.contract
               |> Ecto.Changeset.change(status: "suspended")
               |> repo.update()
             end)

    rejected_evidence =
      recurring_evidence(fixture, agreement, "003", renewed.invoice.billing_period.upper)

    assert {:error, :billing_agreement_unavailable} =
             Billing.reconcile_recurring_invoice(
               fixture.service_scope,
               fixture.provider,
               fixture.merchant_account,
               rejected_evidence
             )

    assert {:error, :billing_agreement_unavailable} =
             Billing.reconcile_recurring_invoice(
               fixture.service_scope,
               fixture.provider,
               fixture.merchant_account,
               rejected_evidence
             )
  end

  test "recurring reconciliation fails closed before any capture for an ineligible graph" do
    fixture = BillingFixtures.create!()

    assert {:ok, order} =
             Billing.place_order(fixture.member_scope, BillingFixtures.checkout_request(fixture))

    agreement = insert_agreement!(fixture, order)
    evidence = recurring_evidence(fixture, agreement, "ineligible", fixture.captured_at)

    assert {:error, :automatic_renewal_not_enabled} =
             Billing.reconcile_recurring_invoice(
               fixture.service_scope,
               fixture.provider,
               fixture.merchant_account,
               evidence
             )

    assert {:error, :automatic_renewal_not_enabled} =
             Billing.reconcile_recurring_invoice(
               fixture.service_scope,
               fixture.provider,
               fixture.merchant_account,
               evidence
             )

    assert {:error, :service_scope_required} =
             Billing.reconcile_recurring_invoice(
               fixture.member_scope,
               fixture.provider,
               fixture.merchant_account,
               evidence
             )

    assert {:error, %Ecto.Changeset{}} =
             Billing.reconcile_recurring_invoice(
               fixture.service_scope,
               fixture.provider,
               fixture.merchant_account,
               %{}
             )

    assert {:ok, %{rows: [[0, 0, 0]]}} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               {:ok,
                repo.query!("""
                SELECT
                  (SELECT count(*) FROM consumer_invoices),
                  (SELECT count(*) FROM payment_intents),
                  (SELECT count(*) FROM payments)
                """)}
             end)
  end

  defp insert_agreement!(fixture, order) do
    assert {:ok, agreement} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               item =
                 repo.one!(
                   from item in OrderItem,
                     where: item.order_id == ^order.id and item.polo_id == ^fixture.polo.id
                 )

               now = DateTime.utc_now(:microsecond)

               agreement =
                 %BillingAgreement{
                   polo_id: fixture.polo.id,
                   user_id: fixture.user.id,
                   product_offering_version_id: fixture.offering_version.id,
                   order_item_id: item.id,
                   merchant_account_id: fixture.merchant_account.id,
                   provider_reference: "subscription-recurring-test",
                   idempotency_key: "recurring-test-agreement",
                   request_sha256: Idempotency.fingerprint({fixture.polo.id, order.id}),
                   status: "pending",
                   next_action: %{},
                   inserted_at: now,
                   updated_at: now
                 }
                 |> repo.insert!()

               {:ok, agreement}
             end)

    agreement
  end

  defp recurring_evidence(fixture, agreement, suffix, occurred_at) do
    %{
      billing_agreement_reference: agreement.provider_reference,
      provider_invoice_reference: "authorized-invoice-#{suffix}",
      provider_payment_reference: "subscription-payment-#{suffix}",
      external_event_id: "subscription-authorized-payment-#{suffix}",
      polo_id: fixture.polo.id,
      order_id: agreement_order_id!(fixture, agreement),
      amount: fixture.price.amount,
      currency: fixture.price.currency,
      occurred_at: occurred_at,
      status: "captured",
      payload: %{"provider" => "mercado_pago", "invoice" => suffix}
    }
  end

  defp agreement_order_id!(fixture, agreement) do
    assert {:ok, order_id} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               {:ok,
                repo.one!(
                  from item in OrderItem,
                    where: item.id == ^agreement.order_item_id,
                    select: item.order_id
                )}
             end)

    order_id
  end

  defp make_automatic!(fixture) do
    assert {:ok, {1, nil}} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               {:ok,
                repo.update_all(
                  from(version in ProductOfferingVersion,
                    where: version.id == ^fixture.offering_version.id
                  ),
                  set: [renewal_policy: "automatic"]
                )}
             end)
  end
end
