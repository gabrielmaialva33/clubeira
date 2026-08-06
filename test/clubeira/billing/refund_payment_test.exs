defmodule Clubeira.Billing.RefundPaymentTest do
  use ClubeiraWeb.ConnCase, async: false

  import Ecto.Query

  alias Clubeira.Billing
  alias Clubeira.Billing.Gateways.MercadoPago
  alias Clubeira.Billing.Payment
  alias Clubeira.BillingFixtures
  alias Clubeira.Events.DomainEvent
  alias Clubeira.Events.OutboxMessage
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  @access_token "test-refund-access-token"

  test "an authorized full refund revokes only the remaining entitlement balance" do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    configure_mercado_pago!(fixture)

    assert {:ok, order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture)
             )

    assert {:ok, contract} =
             Billing.settle_payment(
               fixture.service_scope,
               BillingFixtures.settled_payment(fixture, order)
             )

    payment = payment!(fixture)
    provider_refund_reference = "REF01JQ4S4KY8HWQ6NA5PXB65B3D5"

    Req.Test.expect(MercadoPago, fn request ->
      assert request.method == "POST"
      assert request.request_path == "/v1/orders/#{fixture.provider_reference}/refund"
      assert Plug.Conn.get_req_header(request, "authorization") == ["Bearer #{@access_token}"]
      assert [provider_idempotency_key] =
               Plug.Conn.get_req_header(request, "x-idempotency-key")

      assert {:ok, "{}", request} = Plug.Conn.read_body(request)
      assert {:ok, _refund_id} = Ecto.UUID.cast(provider_idempotency_key)

      request
      |> Plug.Conn.put_status(:created)
      |> Req.Test.json(%{
        id: fixture.provider_reference,
        status: "refunded",
        status_detail: "refunded",
        external_reference: "#{fixture.polo.id}_#{order.id}",
        total_amount: Decimal.to_string(order.total_amount),
        currency: order.currency,
        last_updated_date: DateTime.to_iso8601(DateTime.utc_now(:microsecond)),
        transactions: %{
          payments: [
            %{
              id: fixture.provider_reference,
              status: "refunded",
              status_detail: "refunded",
              amount: Decimal.to_string(order.total_amount)
            }
          ],
          refunds: [
            %{
              id: provider_refund_reference,
              transaction_id: fixture.provider_reference,
              amount: Decimal.to_string(order.total_amount),
              status: "processed"
            }
          ]
        }
      })
    end)

    assert {:ok, refund} =
             Billing.refund_payment(admin_scope, payment.id, %{
               idempotency_key: "refund-payment-001",
               reason: "Cancelamento solicitado pelo assinante"
             })

    assert refund.payment_id == payment.id
    assert refund.provider_reference == provider_refund_reference
    assert refund.status == "succeeded"
    assert Decimal.equal?(refund.amount, payment.amount)

    assert {:ok, :verified} =
             Repo.transact_in_polo(admin_scope, fn repo ->
               assert repo.get!(Payment, payment.id).status == "refunded"

               assert %{rows: [["refunded", "cancelled", "cancelled", 0, 2]]} =
                        repo.query!(
                          """
                          SELECT
                            orders.status,
                            contracts.status,
                            cycles.status,
                            COALESCE(sum(allocations.available_units), 0)::bigint,
                            count(ledger.id)::bigint
                          FROM orders
                          JOIN order_items
                            ON order_items.order_id = orders.id
                           AND order_items.polo_id = orders.polo_id
                          JOIN access_contracts AS contracts
                            ON contracts.order_item_id = order_items.id
                           AND contracts.polo_id = orders.polo_id
                          JOIN benefit_cycles AS cycles
                            ON cycles.access_contract_id = contracts.id
                           AND cycles.polo_id = contracts.polo_id
                          JOIN cycle_entitlement_subjects AS subjects
                            ON subjects.benefit_cycle_id = cycles.id
                           AND subjects.polo_id = cycles.polo_id
                          JOIN entitlement_allocations AS allocations
                            ON allocations.cycle_entitlement_subject_id = subjects.id
                           AND allocations.polo_id = subjects.polo_id
                          LEFT JOIN entitlement_ledger_entries AS ledger
                            ON ledger.entitlement_allocation_id = allocations.id
                           AND ledger.polo_id = allocations.polo_id
                           AND ledger.entry_kind = 'refund_revocation'
                          WHERE orders.id = $1
                            AND orders.polo_id = $2
                            AND contracts.id = $3
                          GROUP BY orders.status, contracts.status, cycles.status
                          """,
                          [order.id, fixture.polo.id, contract.id]
                        )

               refund_event =
                 repo.one!(
                   from(event in DomainEvent,
                     where:
                       event.aggregate_type == "refund" and event.aggregate_id == ^refund.id and
                         event.event_type == "refund.succeeded"
                   )
                 )

               assert refund_event.aggregate_version == 1
               assert repo.get_by!(OutboxMessage, domain_event_id: refund_event.id).topic ==
                        "billing.refunds.succeeded"

               {:ok, :verified}
             end)
  end

  defp payment!(fixture) do
    {:ok, payment} =
      Repo.transact_in_polo(fixture.service_scope, fn repo ->
        {:ok, repo.one!(Payment)}
      end)

    payment
  end

  defp grant_admin!(fixture) do
    ReviewsFixtures.grant_moderator!(
      %{ids: %{polo: fixture.polo.id}, scope: fixture.service_scope},
      role_key: "admin"
    )
  end

  defp configure_mercado_pago!(fixture) do
    fixture.provider
    |> Ecto.Changeset.change(code: "mercado_pago")
    |> Repo.update!()

    previous = Application.get_env(:clubeira, MercadoPago)

    Application.put_env(:clubeira, MercadoPago,
      accounts: %{
        fixture.merchant_account.provider_account_reference => %{
          access_token: @access_token
        }
      },
      req_options: [plug: {Req.Test, MercadoPago}]
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:clubeira, MercadoPago, previous)
      else
        Application.delete_env(:clubeira, MercadoPago)
      end
    end)
  end
end
