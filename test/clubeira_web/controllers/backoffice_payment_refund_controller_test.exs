defmodule ClubeiraWeb.BackofficePaymentRefundControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  import Ecto.Query

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Billing
  alias Clubeira.Billing.Chargeback
  alias Clubeira.Billing.Gateways.MercadoPago
  alias Clubeira.Billing.Payment
  alias Clubeira.BillingFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  @password "uma-senha-forte-para-reembolso"
  @access_token "test-refund-controller-access-token"
  @webhook_secret "test-refund-webhook-secret-with-32-bytes"

  test "an authenticated polo admin issues a full payment refund and sees it in the finance feed",
       %{
         conn: conn
       } do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    admin_token = authenticate!(admin_scope.actor_user_id)
    configure_mercado_pago!(fixture)
    {order, payment} = captured_payment!(fixture)
    provider_refund_reference = "REF01JQ4S4KY8HWQ6NA5PXB65B3E1"

    Req.Test.expect(MercadoPago, fn request ->
      request
      |> Plug.Conn.put_status(:created)
      |> Req.Test.json(refund_order_response(fixture, order, provider_refund_reference))
    end)

    assert %{
             "data" => %{
               "id" => refund_id,
               "payment_id" => payment_id,
               "provider_reference" => ^provider_refund_reference,
               "amount" => amount,
               "status" => "succeeded",
               "requested_at" => requested_at,
               "completed_at" => completed_at
             }
           } =
             conn
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> put_req_header("idempotency-key", "refund-controller-001")
             |> post(
               "/api/v1/polos/#{fixture.polo_route.slug}/backoffice/payments/#{payment.id}/refunds",
               %{"reason" => "Cancelamento validado pelo atendimento"}
             )
             |> json_response(201)

    assert payment_id == payment.id
    assert {:ok, ^refund_id} = Ecto.UUID.cast(refund_id)
    assert Decimal.equal?(Decimal.new(amount), payment.amount)
    assert {:ok, _requested_at, 0} = DateTime.from_iso8601(requested_at)
    assert {:ok, _completed_at, 0} = DateTime.from_iso8601(completed_at)

    assert %{
             "data" => [
               %{
                 "id" => ^payment_id,
                 "status" => "refunded",
                 "amount" => ^amount,
                 "currency" => "BRL",
                 "provider_code" => "mercado_pago",
                 "captured_at" => captured_at,
                 "refunded_at" => refunded_at,
                 "order" => %{
                   "id" => order_id,
                   "order_number" => order_number,
                   "status" => "refunded",
                   "purchaser_user_id" => purchaser_user_id,
                   "placed_at" => placed_at
                 },
                 "refund" =>
                   %{
                     "id" => ^refund_id,
                     "status" => "succeeded",
                     "amount" => ^amount,
                     "requested_at" => ^requested_at,
                     "completed_at" => ^completed_at
                   } = refund_data
               } = payment_data
             ],
             "meta" => %{
               "count" => 1,
               "page" => %{"limit" => 20, "has_more" => false, "next_cursor" => nil}
             }
           } =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get("/api/v1/polos/#{fixture.polo_route.slug}/backoffice/payments")
             |> json_response(200)

    assert order_id == order.id
    assert order_number == order.order_number
    assert purchaser_user_id == fixture.user.id
    assert {:ok, _captured_at, 0} = DateTime.from_iso8601(captured_at)
    assert {:ok, _refunded_at, 0} = DateTime.from_iso8601(refunded_at)
    assert {:ok, _placed_at, 0} = DateTime.from_iso8601(placed_at)
    refute Map.has_key?(payment_data, "provider_reference")
    refute Map.has_key?(payment_data, "idempotency_key")
    refute Map.has_key?(refund_data, "provider_reference")
    refute Map.has_key?(refund_data, "reason")
    refute Map.has_key?(refund_data, "failure_reason")

    subscription_query = URI.encode_query(%{"order_number" => order.order_number})

    assert %{
             "data" => [
               %{
                 "status" => "cancelled",
                 "cancelled_at" => subscription_cancelled_at,
                 "order" => %{"id" => ^order_id, "status" => "refunded"},
                 "current_cycle" => nil,
                 "balance" => %{
                   "issued_units" => 0,
                   "available_units" => 0,
                   "consumed_units" => 0
                 }
               }
             ],
             "meta" => %{"count" => 1}
           } =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(
               "/api/v1/polos/#{fixture.polo_route.slug}/backoffice/subscriptions?#{subscription_query}"
             )
             |> json_response(200)

    assert {:ok, _subscription_cancelled_at, 0} =
             DateTime.from_iso8601(subscription_cancelled_at)
  end

  test "the finance feed filters and paginates payments without leaking support-only fields", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    admin_token = authenticate!(admin_scope.actor_user_id)
    {older_order, older_payment} = captured_payment!(fixture)

    {newer_order, newer_payment} =
      captured_payment!(fixture, %{
        external_event_id: "evt-#{Ecto.UUID.generate()}",
        provider_reference: "pay-#{Ecto.UUID.generate()}",
        occurred_at: DateTime.add(fixture.captured_at, 1, :microsecond)
      })

    path = "/api/v1/polos/#{fixture.polo_route.slug}/backoffice/payments"

    assert %{
             "data" => [%{"id" => newer_payment_id, "refund" => nil} = payment_data],
             "meta" => %{
               "count" => 1,
               "page" => %{"limit" => 1, "has_more" => true, "next_cursor" => cursor}
             }
           } =
             conn
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(path <> "?limit=1&status=captured")
             |> json_response(200)

    assert newer_payment_id == newer_payment.id
    assert is_binary(cursor)
    refute cursor =~ newer_payment.id
    refute Map.has_key?(payment_data, "provider_reference")
    refute Map.has_key?(payment_data, "idempotency_key")

    assert %{
             "data" => [%{"id" => older_payment_id}],
             "meta" => %{
               "count" => 1,
               "page" => %{"limit" => 1, "has_more" => false, "next_cursor" => nil}
             }
           } =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(path <> "?limit=1&status=captured&after=#{cursor}")
             |> json_response(200)

    assert older_payment_id == older_payment.id

    query = URI.encode_query(%{"order_number" => older_order.order_number})

    assert %{
             "data" => [%{"id" => ^older_payment_id, "order" => %{"id" => older_order_id}}]
           } =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(path <> "?#{query}")
             |> json_response(200)

    assert older_order_id == older_order.id
    refute older_order.id == newer_order.id

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> get(path <> "?limit=0")
           |> json_response(400) == %{"errors" => %{"detail" => "Bad Request"}}

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> get(path <> "?after=not-a-cursor")
           |> json_response(400) == %{"errors" => %{"detail" => "Bad Request"}}

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> get(path <> "?status=unknown")
           |> json_response(422) == %{
             "errors" => %{"detail" => "Unprocessable Content"}
           }
  end

  test "the finance feed exposes a safe chargeback summary and supports its terminal status", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    admin_token = authenticate!(admin_scope.actor_user_id)
    {_order, payment} = captured_payment!(fixture)
    opened_at = DateTime.utc_now(:microsecond)

    {:ok, chargeback} =
      Repo.transact_in_polo(fixture.service_scope, fn repo ->
        payment =
          payment
          |> Ecto.Changeset.change(status: "charged_back", charged_back_at: opened_at)
          |> repo.update!()

        chargeback =
          repo.insert!(%Chargeback{
            polo_id: fixture.polo.id,
            payment_id: payment.id,
            provider_reference: "chargeback-private-reference",
            amount: payment.amount,
            reason_code: "private-provider-reason",
            status: "lost",
            opened_at: opened_at,
            closed_at: opened_at,
            inserted_at: opened_at,
            updated_at: opened_at
          })

        {:ok, chargeback}
      end)

    assert %{
             "data" => [
               %{
                 "id" => payment_id,
                 "status" => "charged_back",
                 "chargeback" =>
                   %{
                     "id" => chargeback_id,
                     "status" => "lost",
                     "amount" => amount,
                     "opened_at" => opened_at_string,
                     "closed_at" => closed_at_string
                   } = chargeback_data
               }
             ]
           } =
             conn
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(
               "/api/v1/polos/#{fixture.polo_route.slug}/backoffice/payments?status=charged_back"
             )
             |> json_response(200)

    assert payment_id == payment.id
    assert chargeback_id == chargeback.id
    assert Decimal.equal?(Decimal.new(amount), chargeback.amount)
    assert {:ok, _opened_at, 0} = DateTime.from_iso8601(opened_at_string)
    assert {:ok, _closed_at, 0} = DateTime.from_iso8601(closed_at_string)
    refute Map.has_key?(chargeback_data, "provider_reference")
    refute Map.has_key?(chargeback_data, "reason_code")
  end

  test "the finance feed authorizes the actor in the routed polo and never crosses tenants", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    other_polo = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    admin_token = authenticate!(admin_scope.actor_user_id)
    member_token = authenticate!(fixture.user.id)
    {_order, payment} = captured_payment!(fixture)
    {_other_order, other_payment} = captured_payment!(other_polo)
    path = "/api/v1/polos/#{fixture.polo_route.slug}/backoffice/payments"

    assert conn
           |> put_req_header("authorization", "Bearer #{member_token}")
           |> get(path)
           |> json_response(403) == %{"errors" => %{"detail" => "Forbidden"}}

    assert %{"data" => [%{"id" => payment_id}]} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(path)
             |> json_response(200)

    assert payment_id == payment.id
    refute payment_id == other_payment.id
  end

  test "an authenticated webhook reconciles a refund after an ambiguous API timeout", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    admin_token = authenticate!(admin_scope.actor_user_id)
    configure_mercado_pago!(fixture)
    {order, payment} = captured_payment!(fixture)

    path =
      "/api/v1/polos/#{fixture.polo_route.slug}/backoffice/payments/#{payment.id}/refunds"

    body = %{"reason" => "Reembolso confirmado durante atendimento"}
    key = "refund-timeout-webhook-001"

    Req.Test.expect(MercadoPago, fn request ->
      Req.Test.transport_error(request, :timeout)
    end)

    assert conn
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", key)
           |> post(path, body)
           |> json_response(503) == %{
             "errors" => %{"detail" => "Service Unavailable"}
           }

    provider_refund_reference = "REF01JQ4S4KY8HWQ6NA5PXB65B3E2"

    Req.Test.expect(MercadoPago, fn request ->
      assert request.method == "GET"
      assert request.request_path == "/v1/orders/#{fixture.provider_reference}"
      Req.Test.json(request, refund_order_response(fixture, order, provider_refund_reference))
    end)

    provider_request_id = Ecto.UUID.generate()

    signature =
      webhook_signature(fixture.provider_reference, provider_request_id, @webhook_secret)

    query = URI.encode_query(%{"data.id" => fixture.provider_reference, "type" => "order"})

    assert conn
           |> recycle()
           |> put_req_header("x-request-id", provider_request_id)
           |> put_req_header("x-signature", signature)
           |> post(
             "/api/v1/webhooks/mercado-pago/#{fixture.merchant_account.id}?#{query}",
             %{
               "action" => "order.refunded",
               "type" => "order",
               "data" => %{"id" => fixture.provider_reference}
             }
           )
           |> response(200) == ""

    assert %{"data" => %{"status" => "succeeded", "id" => refund_id}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> put_req_header("idempotency-key", key)
             |> post(path, body)
             |> json_response(201)

    assert {:ok, ^refund_id} = Ecto.UUID.cast(refund_id)
  end

  test "refund authorization is tenant-scoped and hides payments from another polo", %{conn: conn} do
    fixture = BillingFixtures.create!()
    other_polo = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    admin_token = authenticate!(admin_scope.actor_user_id)
    member_token = authenticate!(fixture.user.id)
    {_order, payment} = captured_payment!(fixture)
    {_other_order, other_payment} = captured_payment!(other_polo)
    body = %{"reason" => "Solicitação analisada pelo atendimento"}

    assert conn
           |> put_req_header("authorization", "Bearer #{member_token}")
           |> put_req_header("idempotency-key", "refund-member-forbidden")
           |> post(refund_path(fixture, payment), body)
           |> json_response(403) == %{"errors" => %{"detail" => "Forbidden"}}

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "refund-cross-polo-hidden")
           |> post(refund_path(fixture, other_payment), body)
           |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}
  end

  test "a provider-initiated full refund is imported by the authenticated webhook", %{conn: conn} do
    fixture = BillingFixtures.create!()
    configure_mercado_pago!(fixture)
    {order, payment} = captured_payment!(fixture)
    provider_refund_reference = "REF01JQ4S4KY8HWQ6NA5PXB65B3E3"

    Req.Test.expect(MercadoPago, fn request ->
      Req.Test.json(request, refund_order_response(fixture, order, provider_refund_reference))
    end)

    provider_request_id = Ecto.UUID.generate()

    signature =
      webhook_signature(fixture.provider_reference, provider_request_id, @webhook_secret)

    query = URI.encode_query(%{"data.id" => fixture.provider_reference, "type" => "order"})

    assert conn
           |> put_req_header("x-request-id", provider_request_id)
           |> put_req_header("x-signature", signature)
           |> post(
             "/api/v1/webhooks/mercado-pago/#{fixture.merchant_account.id}?#{query}",
             %{
               "action" => "order.refunded",
               "type" => "order",
               "data" => %{"id" => fixture.provider_reference}
             }
           )
           |> response(200) == ""

    assert {:ok, :verified} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               refund = repo.one!(Clubeira.Billing.Refund)
               assert refund.payment_id == payment.id
               assert refund.provider_reference == provider_refund_reference
               assert refund.status == "succeeded"
               assert refund.reason == "provider_initiated"
               assert is_nil(refund.requested_by_user_id)
               assert repo.get!(Payment, payment.id).status == "refunded"
               {:ok, :verified}
             end)
  end

  test "invalid refund contracts fail before provider I/O", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    admin_token = authenticate!(admin_scope.actor_user_id)
    {_order, payment} = captured_payment!(fixture)
    path = refund_path(fixture, payment)

    assert conn
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> post(path, %{"reason" => "Header ausente"})
           |> json_response(400) == %{
             "errors" => %{"code" => "invalid_idempotency_key", "detail" => "Bad Request"}
           }

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "short")
           |> post(path, %{"reason" => "  "})
           |> json_response(422) == %{
             "errors" => %{"detail" => "Unprocessable Content"}
           }

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "refund-invalid-payment-id")
           |> post(
             "/api/v1/polos/#{fixture.polo_route.slug}/backoffice/payments/not-a-uuid/refunds",
             %{"reason" => "Identidade externa inválida"}
           )
           |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}
  end

  defp captured_payment!(fixture, settlement_overrides \\ %{}) do
    assert {:ok, order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture)
             )

    assert {:ok, _contract} =
             Billing.settle_payment(
               fixture.service_scope,
               BillingFixtures.settled_payment(fixture, order, settlement_overrides)
             )

    provider_reference =
      Map.get(settlement_overrides, :provider_reference, fixture.provider_reference)

    {:ok, payment} =
      Repo.transact_in_polo(fixture.service_scope, fn repo ->
        {:ok,
         repo.one!(
           from(payment in Payment,
             where:
               payment.polo_id == ^fixture.polo.id and
                 payment.provider_reference == ^provider_reference
           )
         )}
      end)

    {order, payment}
  end

  defp refund_path(fixture, payment) do
    "/api/v1/polos/#{fixture.polo_route.slug}/backoffice/payments/#{payment.id}/refunds"
  end

  defp grant_admin!(fixture) do
    ReviewsFixtures.grant_moderator!(
      %{ids: %{polo: fixture.polo.id}, scope: fixture.service_scope},
      role_key: "admin"
    )
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session.token
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

  defp webhook_signature(data_id, request_id, secret) do
    timestamp = System.system_time(:millisecond) |> Integer.to_string()
    manifest = "id:#{data_id};request-id:#{request_id};ts:#{timestamp};"

    digest =
      :crypto.mac(:hmac, :sha256, secret, manifest)
      |> Base.encode16(case: :lower)

    "ts=#{timestamp},v1=#{digest}"
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
end
