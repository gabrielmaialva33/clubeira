defmodule Clubeira.Billing.RefundPaymentTest do
  use ClubeiraWeb.ConnCase, async: false

  import Ecto.Query

  alias Clubeira.Audit.TenantEvent
  alias Clubeira.Billing
  alias Clubeira.Billing.Gateways.MercadoPago
  alias Clubeira.Billing.Payment
  alias Clubeira.Billing.RefundRequest
  alias Clubeira.BillingFixtures
  alias Clubeira.Events.DomainEvent
  alias Clubeira.Events.OutboxMessage
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  @access_token "test-refund-access-token"

  test "the refund form boundary rejects non-map and struct payloads without raising" do
    Enum.each([:invalid, %Clubeira.Billing.RefundRequest{}], fn attributes ->
      changeset = Billing.change_refund_request(attributes)

      refute changeset.valid?
      assert {:base, {"must be a map", []}} in changeset.errors
    end)
  end

  test "the refund command normalizes reason and validates its replay identity" do
    assert {:ok, request} =
             RefundRequest.new(%{
               "reason" => "  Cancelamento solicitado  ",
               "idempotency_key" => "refund-request-001"
             })

    assert request.reason == "Cancelamento solicitado"

    for attributes <- [
          :invalid,
          %URI{},
          %{},
          %{"reason" => "x", "idempotency_key" => "refund-request-002"},
          %{"reason" => "Motivo válido", "idempotency_key" => "invalid key"}
        ] do
      assert {:error, changeset} = RefundRequest.new(attributes)
      refute changeset.valid?
    end
  end

  test "an authorized full refund revokes remaining balance without erasing issuance history" do
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
      |> Req.Test.json(refund_order_response(fixture, order, provider_refund_reference))
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
                          [
                            Ecto.UUID.dump!(order.id),
                            Ecto.UUID.dump!(fixture.polo.id),
                            Ecto.UUID.dump!(contract.id)
                          ]
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

               outbox = repo.get_by!(OutboxMessage, domain_event_id: refund_event.id)
               assert outbox.topic == "billing.refunds.succeeded"

               audit =
                 repo.get_by!(TenantEvent,
                   action: "refund.succeeded",
                   resource_id: refund.id
                 )

               assert audit.metadata["reason"] == "Cancelamento solicitado pelo assinante"

               assert repo.aggregate(
                        from(entry in Clubeira.Subscriptions.EntitlementLedgerEntry,
                          where: entry.entry_kind == "initial_grant"
                        ),
                        :count
                      ) == 2

               refute inspect([refund_event.payload, refund_event.metadata, outbox.payload]) =~
                        "Cancelamento solicitado pelo assinante"

               {:ok, :verified}
             end)
  end

  test "a retry after an ambiguous provider failure reuses the reserved refund" do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    configure_mercado_pago!(fixture)
    {order, payment} = captured_payment!(fixture)

    attributes = %{
      idempotency_key: "refund-ambiguous-retry",
      reason: "Solicitação de cancelamento confirmada"
    }

    test_process = self()

    Req.Test.expect(MercadoPago, fn request ->
      [provider_key] = Plug.Conn.get_req_header(request, "x-idempotency-key")
      send(test_process, {:provider_key, provider_key})
      Req.Test.transport_error(request, :timeout)
    end)

    assert {:error, :payment_gateway_unavailable} =
             Billing.refund_payment(admin_scope, payment.id, attributes)

    assert_receive {:provider_key, first_provider_key}

    Req.Test.expect(MercadoPago, fn request ->
      [provider_key] = Plug.Conn.get_req_header(request, "x-idempotency-key")
      send(test_process, {:provider_key, provider_key})

      request
      |> Plug.Conn.put_status(:created)
      |> Req.Test.json(refund_order_response(fixture, order, "REF01JQ4S4KY8HWQ6NA5PXB65B3D6"))
    end)

    assert {:ok, refund} = Billing.refund_payment(admin_scope, payment.id, attributes)
    assert_receive {:provider_key, second_provider_key}
    assert first_provider_key == refund.id
    assert second_provider_key == first_provider_key

    assert {:ok, replayed} = Billing.refund_payment(admin_scope, payment.id, attributes)
    assert replayed.id == refund.id
  end

  test "a definitive provider rejection is stable and leaves the captured sale untouched" do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    configure_mercado_pago!(fixture)
    {order, payment} = captured_payment!(fixture)

    attributes = %{
      idempotency_key: "refund-definitive-rejection",
      reason: "Pedido revisado e aprovado pelo atendimento"
    }

    Req.Test.expect(MercadoPago, fn request ->
      request
      |> Plug.Conn.put_status(:bad_request)
      |> Req.Test.json(%{message: "refund_not_available"})
    end)

    assert {:error, :payment_gateway_rejected} =
             Billing.refund_payment(admin_scope, payment.id, attributes)

    assert {:error, :payment_gateway_rejected} =
             Billing.refund_payment(admin_scope, payment.id, attributes)

    assert {:ok, :verified} =
             Repo.transact_in_polo(admin_scope, fn repo ->
               refund = repo.one!(Clubeira.Billing.Refund)
               assert refund.status == "failed"
               assert refund.failure_reason == "payment_gateway_rejected"
               assert repo.get!(Payment, payment.id).status == "captured"

               assert repo.one!(
                        from(persisted_order in Clubeira.Subscriptions.Order,
                          where: persisted_order.id == ^order.id,
                          select: persisted_order.status
                        )
                      ) == "paid"

               refute repo.exists?(
                        from(event in DomainEvent,
                          where: event.event_type == "refund.succeeded"
                        )
                      )

               {:ok, :verified}
             end)
  end

  test "the same idempotency key cannot be reused with another reason" do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    configure_mercado_pago!(fixture)
    {_order, payment} = captured_payment!(fixture)

    Req.Test.expect(MercadoPago, fn request ->
      Req.Test.transport_error(request, :timeout)
    end)

    assert {:error, :payment_gateway_unavailable} =
             Billing.refund_payment(admin_scope, payment.id, %{
               idempotency_key: "refund-conflicting-reuse",
               reason: "Motivo original validado"
             })

    assert {:error, :idempotency_conflict} =
             Billing.refund_payment(admin_scope, payment.id, %{
               idempotency_key: "refund-conflicting-reuse",
               reason: "Outro motivo para a mesma chave"
             })
  end

  defp payment!(fixture) do
    {:ok, payment} =
      Repo.transact_in_polo(fixture.service_scope, fn repo ->
        {:ok, repo.one!(Payment)}
      end)

    payment
  end

  defp captured_payment!(fixture) do
    assert {:ok, order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture)
             )

    assert {:ok, _contract} =
             Billing.settle_payment(
               fixture.service_scope,
               BillingFixtures.settled_payment(fixture, order)
             )

    {order, payment!(fixture)}
  end

  defp refund_order_response(fixture, order, provider_refund_reference) do
    %{
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
    }
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
