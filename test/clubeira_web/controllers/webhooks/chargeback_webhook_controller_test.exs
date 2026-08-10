defmodule ClubeiraWeb.Webhooks.ChargebackWebhookControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  import Ecto.Query

  alias Clubeira.Audit.TenantEvent
  alias Clubeira.Billing
  alias Clubeira.Billing.Gateways.MercadoPago
  alias Clubeira.Billing.Payment
  alias Clubeira.Billing.PaymentProviderEvent
  alias Clubeira.BillingFixtures
  alias Clubeira.Events.DomainEvent
  alias Clubeira.Events.OutboxMessage
  alias Clubeira.Repo
  alias Clubeira.Subscriptions.AccessContract
  alias Clubeira.Subscriptions.BenefitCycle
  alias Clubeira.Subscriptions.ContractSuspension
  alias Clubeira.Subscriptions.EntitlementAllocation
  alias Clubeira.Subscriptions.EntitlementLedgerEntry
  alias Clubeira.Subscriptions.Order

  @access_token "test-chargeback-access-token"
  @webhook_secret "test-chargeback-webhook-secret-with-at-least-32-bytes"

  test "an authenticated chargeback suspends access and a loss revokes it atomically", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    configure_mercado_pago!(fixture)
    {order, contract, payment} = captured_sale!(fixture)

    chargeback_reference = "233000061680860000"
    opened_at = DateTime.utc_now(:microsecond)

    expect_chargeback_fetch!(fixture, order, payment, chargeback_reference,
      coverage_applied: nil,
      documentation_status: "not_supplied",
      occurred_at: opened_at
    )

    assert send_chargeback_webhook(conn, fixture, chargeback_reference, payment, "opened") == 200

    assert {:ok, :suspended} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               chargeback = repo.one!(Clubeira.Billing.Chargeback)
               assert chargeback.status == "open"
               assert chargeback.provider_reference == chargeback_reference
               assert Decimal.equal?(chargeback.amount, payment.amount)
               assert repo.get!(AccessContract, contract.id).status == "suspended"
               assert repo.get!(Payment, payment.id).status == "captured"
               assert repo.get!(Order, order.id).status == "paid"

               suspension = repo.one!(ContractSuspension)
               assert suspension.reason == "chargeback:#{chargeback.id}"
               assert suspension.suspended_during.upper == :unbound

               assert repo.aggregate(
                        from(entry in EntitlementLedgerEntry,
                          where: entry.entry_kind == "chargeback_revocation"
                        ),
                        :count
                      ) == 0

               {:ok, :suspended}
             end)

    lost_at = DateTime.add(opened_at, 1, :second)

    expect_chargeback_fetch!(fixture, order, payment, chargeback_reference,
      coverage_applied: false,
      documentation_status: "valid",
      opened_at: opened_at,
      occurred_at: lost_at
    )

    assert send_chargeback_webhook(conn, fixture, chargeback_reference, payment, "lost") == 200

    expect_chargeback_fetch!(fixture, order, payment, chargeback_reference,
      coverage_applied: false,
      documentation_status: "valid",
      opened_at: opened_at,
      occurred_at: lost_at
    )

    assert send_chargeback_webhook(conn, fixture, chargeback_reference, payment, "lost-replay") ==
             200

    assert {:ok, :revoked} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               chargeback = repo.one!(Clubeira.Billing.Chargeback)
               assert chargeback.status == "lost"
               assert chargeback.closed_at
               assert repo.get!(AccessContract, contract.id).status == "cancelled"
               assert repo.get!(Payment, payment.id).status == "charged_back"
               assert repo.get!(Order, order.id).status == "charged_back"
               assert repo.one!(from(cycle in BenefitCycle, select: cycle.status)) == "cancelled"
               assert repo.aggregate(EntitlementAllocation, :sum, :available_units) == 0

               assert repo.aggregate(
                        from(entry in EntitlementLedgerEntry,
                          where: entry.entry_kind == "chargeback_revocation"
                        ),
                        :count
                      ) == 2

               suspension = repo.one!(ContractSuspension)
               refute suspension.suspended_during.upper == :unbound

               assert repo.aggregate(
                        from(event in DomainEvent,
                          where:
                            event.aggregate_type == "chargeback" and
                              event.aggregate_id == ^chargeback.id
                        ),
                        :count
                      ) == 2

               lost_event =
                 repo.get_by!(DomainEvent,
                   aggregate_type: "chargeback",
                   aggregate_id: chargeback.id,
                   event_type: "chargeback.lost"
                 )

               assert repo.get_by!(OutboxMessage, domain_event_id: lost_event.id).topic ==
                        "billing.chargebacks.lost"

               assert repo.get_by!(TenantEvent,
                        action: "chargeback.lost",
                        resource_id: chargeback.id
                      )

               assert repo.aggregate(
                        from(event in PaymentProviderEvent,
                          where: like(event.event_type, "chargeback.%")
                        ),
                        :count
                      ) == 2

               {:ok, :revoked}
             end)
  end

  test "a won chargeback restores the status that existed before its suspension", %{conn: conn} do
    fixture = BillingFixtures.create!()
    configure_mercado_pago!(fixture)
    {order, contract, payment} = captured_sale!(fixture)

    chargeback_reference = "233000061680860001"
    opened_at = DateTime.utc_now(:microsecond)

    expect_chargeback_fetch!(fixture, order, payment, chargeback_reference,
      coverage_applied: nil,
      documentation_status: "review_pending",
      occurred_at: opened_at
    )

    assert send_chargeback_webhook(conn, fixture, chargeback_reference, payment, "opened") == 200

    won_at = DateTime.add(opened_at, 1, :second)

    expect_chargeback_fetch!(fixture, order, payment, chargeback_reference,
      coverage_applied: true,
      documentation_status: "valid",
      opened_at: opened_at,
      occurred_at: won_at
    )

    assert send_chargeback_webhook(conn, fixture, chargeback_reference, payment, "won") == 200

    assert {:ok, :restored} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               chargeback = repo.one!(Clubeira.Billing.Chargeback)
               assert chargeback.status == "won"
               assert repo.get!(AccessContract, contract.id).status == "active"
               assert repo.get!(Payment, payment.id).status == "captured"
               assert repo.get!(Order, order.id).status == "paid"
               assert repo.one!(from(cycle in BenefitCycle, select: cycle.status)) == "active"
               assert repo.aggregate(EntitlementAllocation, :sum, :available_units) == 2

               assert repo.aggregate(
                        from(entry in EntitlementLedgerEntry,
                          where: entry.entry_kind == "chargeback_revocation"
                        ),
                        :count
                      ) == 0

               suspension = repo.one!(ContractSuspension)
               refute suspension.suspended_during.upper == :unbound

               assert repo.get_by!(TenantEvent,
                        action: "chargeback.won",
                        resource_id: chargeback.id
                      )

               {:ok, :restored}
             end)
  end

  defp captured_sale!(fixture) do
    assert {:ok, order} =
             Billing.place_order(fixture.member_scope, BillingFixtures.checkout_request(fixture))

    assert {:ok, contract} =
             Billing.settle_payment(
               fixture.service_scope,
               BillingFixtures.settled_payment(fixture, order)
             )

    {:ok, payment} =
      Repo.transact_in_polo(fixture.service_scope, fn repo -> {:ok, repo.one!(Payment)} end)

    {order, contract, payment}
  end

  defp expect_chargeback_fetch!(fixture, order, payment, reference, options) do
    occurred_at = Keyword.fetch!(options, :occurred_at)
    coverage_applied = Keyword.fetch!(options, :coverage_applied)
    documentation_status = Keyword.fetch!(options, :documentation_status)

    Req.Test.expect(MercadoPago, 2, fn request ->
      assert Plug.Conn.get_req_header(request, "authorization") == ["Bearer #{@access_token}"]

      case request.request_path do
        "/v1/chargebacks/" <> ^reference ->
          Req.Test.json(request, %{
            id: reference,
            payments: [payment.provider_reference],
            currency: payment.currency,
            amount: Decimal.to_string(payment.amount),
            reason: "fraud",
            coverage_applied: coverage_applied,
            coverage_elegible: true,
            documentation_required: false,
            documentation_status: documentation_status,
            documentation: [],
            date_created: DateTime.to_iso8601(opened_at(options)),
            date_last_updated: DateTime.to_iso8601(occurred_at),
            live_mode: false
          })

        "/v1/payments/" <> provider_payment_reference ->
          assert provider_payment_reference == payment.provider_reference

          Req.Test.json(request, %{
            id: payment.provider_reference,
            external_reference: "#{fixture.polo.id}_#{order.id}",
            currency_id: payment.currency,
            transaction_amount: Decimal.to_string(payment.amount)
          })
      end
    end)
  end

  defp opened_at(options),
    do: Keyword.get(options, :opened_at, Keyword.fetch!(options, :occurred_at))

  defp send_chargeback_webhook(conn, fixture, reference, payment, request_suffix) do
    provider_request_id = Ecto.UUID.generate()
    signature = webhook_signature(reference, provider_request_id)
    query = URI.encode_query(%{"data.id" => reference, "type" => "topic_chargebacks_wh"})

    conn
    |> recycle()
    |> put_req_header("x-request-id", provider_request_id)
    |> put_req_header("x-signature", signature)
    |> post(
      "/api/v1/webhooks/mercado-pago/#{fixture.merchant_account.id}?#{query}",
      %{
        "actions" => ["changed_case_status"],
        "id" => request_suffix,
        "type" => "topic_chargebacks_wh",
        "data" => %{
          "id" => String.to_integer(reference),
          "payment_id" => payment.provider_reference
        }
      }
    )
    |> Map.fetch!(:status)
  end

  defp webhook_signature(data_id, request_id) do
    timestamp = System.system_time(:millisecond) |> Integer.to_string()
    manifest = "id:#{data_id};request-id:#{request_id};ts:#{timestamp};"

    digest =
      :crypto.mac(:hmac, :sha256, @webhook_secret, manifest)
      |> Base.encode16(case: :lower)

    "ts=#{timestamp},v1=#{digest}"
  end

  defp configure_mercado_pago!(fixture) do
    fixture.provider
    |> Ecto.Changeset.change(code: "mercado_pago")
    |> Repo.update!()

    previous = Application.get_env(:clubeira, MercadoPago)

    Application.put_env(:clubeira, MercadoPago,
      accounts: %{
        fixture.merchant_account.provider_account_reference => %{
          access_token: @access_token,
          webhook_secret: @webhook_secret
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
