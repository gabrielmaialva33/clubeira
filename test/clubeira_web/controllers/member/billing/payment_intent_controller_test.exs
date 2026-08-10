defmodule ClubeiraWeb.Member.PaymentIntentControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Billing
  alias Clubeira.Billing.Gateways.MercadoPago
  alias Clubeira.Billing.Payment
  alias Clubeira.Billing.PaymentProviderEvent
  alias Clubeira.BillingFixtures
  alias Clubeira.Repo
  alias Clubeira.Subscriptions.AccessContract

  @password "uma-senha-de-pagamento-forte"
  @access_token "test-access-token"
  @webhook_secret "test-webhook-secret-with-at-least-32-bytes"

  test "an authenticated member starts a Pix payment for their pending order", %{conn: conn} do
    fixture = BillingFixtures.create!()
    configure_mercado_pago!(fixture)
    token = authenticate!(fixture)

    assert {:ok, order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture)
             )

    provider_reference = "ORD01JQ4S4KY8HWQ6NA5PXB65B3D3"
    payment_reference = "PAY01JQ4S4KY8HWQ6NA5PXB65B3D4"
    redirect_url = "https://www.mercadopago.com.br/sandbox/payments/example/ticket"
    copy_paste_code = "000201010212example-pix-code"

    Req.Test.expect(MercadoPago, fn request ->
      assert request.method == "POST"
      assert request.request_path == "/v1/orders"
      assert get_req_header(request, "authorization") == ["Bearer #{@access_token}"]
      assert [_idempotency_key] = get_req_header(request, "x-idempotency-key")

      {:ok, body, request} = read_body(request)

      assert %{
               "type" => "online",
               "processing_mode" => "automatic",
               "external_reference" => order_id,
               "total_amount" => total_amount,
               "payer" => %{"email" => payer_email},
               "transactions" => %{
                 "payments" => [
                   %{
                     "amount" => payment_amount,
                     "payment_method" => %{"id" => "pix", "type" => "bank_transfer"},
                     "expiration_time" => "PT30M"
                   }
                 ]
               }
             } = Jason.decode!(body)

      assert order_id == "#{fixture.polo.id}_#{order.id}"
      assert payer_email == fixture.user.email
      assert Decimal.equal?(Decimal.new(total_amount), order.total_amount)
      assert Decimal.equal?(Decimal.new(payment_amount), order.total_amount)

      request
      |> put_status(:created)
      |> Req.Test.json(%{
        id: provider_reference,
        status: "action_required",
        transactions: %{
          payments: [
            %{
              id: payment_reference,
              status: "action_required",
              amount: Decimal.to_string(order.total_amount),
              payment_method: %{
                id: "pix",
                type: "bank_transfer",
                ticket_url: redirect_url,
                qr_code: copy_paste_code,
                qr_code_base64: "ignored"
              }
            }
          ]
        }
      })
    end)

    response =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("idempotency-key", "payment-api-001")
      |> post(~p"/api/v1/polos/#{fixture.polo_route.slug}/orders/#{order.id}/payment-intents", %{
        "payment_method" => "pix"
      })
      |> json_response(201)

    assert %{
             "data" => %{
               "id" => payment_intent_id,
               "order_id" => order_id,
               "provider" => "mercado_pago",
               "provider_reference" => ^provider_reference,
               "payment_method" => "pix",
               "status" => "requires_action",
               "amount" => amount,
               "currency" => "BRL",
               "expires_at" => expires_at,
               "next_action" => %{
                 "type" => "pix",
                 "redirect_url" => ^redirect_url,
                 "copy_paste_code" => ^copy_paste_code
               }
             }
           } = response

    assert {:ok, ^payment_intent_id} = Ecto.UUID.cast(payment_intent_id)
    assert order_id == order.id
    assert Decimal.equal?(Decimal.new(amount), order.total_amount)
    assert {:ok, _expires_at, 0} = DateTime.from_iso8601(expires_at)
  end

  test "replaying a completed payment start returns the same intent without calling the provider again",
       %{conn: conn} do
    fixture = BillingFixtures.create!()
    configure_mercado_pago!(fixture)
    token = authenticate!(fixture)

    assert {:ok, order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture)
             )

    provider_reference = "ORD01JQ4S4KY8HWQ6NA5PXB65B3D3"
    payment_reference = "PAY01JQ4S4KY8HWQ6NA5PXB65B3D4"

    Req.Test.expect(MercadoPago, fn request ->
      request
      |> put_status(:created)
      |> Req.Test.json(
        pix_order_response(order, provider_reference, payment_reference,
          status: "action_required"
        )
      )
    end)

    request_path =
      ~p"/api/v1/polos/#{fixture.polo_route.slug}/orders/#{order.id}/payment-intents"

    first =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("idempotency-key", "payment-api-replay")
      |> post(request_path, %{"payment_method" => "pix"})
      |> json_response(201)

    replayed =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("idempotency-key", "payment-api-replay")
      |> post(request_path, %{"payment_method" => "pix"})
      |> json_response(201)

    assert replayed == first
  end

  test "retrying after an ambiguous provider failure reuses the local intent and provider idempotency key" do
    fixture = BillingFixtures.create!()
    configure_mercado_pago!(fixture)

    assert {:ok, order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture)
             )

    test_process = self()

    Req.Test.expect(MercadoPago, fn request ->
      [provider_idempotency_key] = get_req_header(request, "x-idempotency-key")
      send(test_process, {:provider_idempotency_key, provider_idempotency_key})
      Req.Test.transport_error(request, :timeout)
    end)

    request = %{
      order_id: order.id,
      payment_method: "pix",
      idempotency_key: "payment-provider-retry"
    }

    assert {:error, :payment_gateway_unavailable} =
             Billing.start_payment(fixture.member_scope, request)

    assert_receive {:provider_idempotency_key, first_provider_key}

    provider_reference = "ORD01JQ4S4KY8HWQ6NA5PXB65B3D3"
    payment_reference = "PAY01JQ4S4KY8HWQ6NA5PXB65B3D4"

    Req.Test.expect(MercadoPago, fn provider_request ->
      [provider_idempotency_key] = get_req_header(provider_request, "x-idempotency-key")
      send(test_process, {:provider_idempotency_key, provider_idempotency_key})

      provider_request
      |> put_status(:created)
      |> Req.Test.json(
        pix_order_response(order, provider_reference, payment_reference,
          status: "action_required"
        )
      )
    end)

    assert {:ok, %{payment_intent: intent}} =
             Billing.start_payment(fixture.member_scope, request)

    assert_receive {:provider_idempotency_key, second_provider_key}
    assert first_provider_key == intent.id
    assert second_provider_key == first_provider_key
  end

  test "a second live payment attempt for the same order conflicts before calling the provider",
       %{conn: conn} do
    fixture = BillingFixtures.create!()
    configure_mercado_pago!(fixture)
    token = authenticate!(fixture)

    assert {:ok, order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture)
             )

    Req.Test.expect(MercadoPago, fn request ->
      request
      |> put_status(:created)
      |> Req.Test.json(
        pix_order_response(
          order,
          "ORD01JQ4S4KY8HWQ6NA5PXB65B3D3",
          "PAY01JQ4S4KY8HWQ6NA5PXB65B3D4",
          status: "action_required"
        )
      )
    end)

    request_path =
      ~p"/api/v1/polos/#{fixture.polo_route.slug}/orders/#{order.id}/payment-intents"

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", "payment-first-attempt")
           |> post(request_path, %{"payment_method" => "pix"})
           |> json_response(201)

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", "payment-second-attempt")
           |> post(request_path, %{"payment_method" => "pix"})
           |> json_response(409) == %{"errors" => %{"detail" => "Conflict"}}
  end

  test "an authenticated member cannot start another member's order", %{conn: conn} do
    fixture = BillingFixtures.create!()
    another_member = BillingFixtures.create!()
    configure_mercado_pago!(fixture)
    token = authenticate!(another_member)

    assert {:ok, order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture)
             )

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", "payment-wrong-member")
           |> post(
             ~p"/api/v1/polos/#{fixture.polo_route.slug}/orders/#{order.id}/payment-intents",
             %{"payment_method" => "pix"}
           )
           |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}
  end

  test "payment start requires authentication, one idempotency key and a supported method",
       %{conn: conn} do
    fixture = BillingFixtures.create!()
    configure_mercado_pago!(fixture)
    token = authenticate!(fixture)

    assert {:ok, order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture)
             )

    request_path =
      ~p"/api/v1/polos/#{fixture.polo_route.slug}/orders/#{order.id}/payment-intents"

    assert conn
           |> put_req_header("idempotency-key", "payment-without-session")
           |> post(request_path, %{"payment_method" => "pix"})
           |> json_response(401) == %{"errors" => %{"detail" => "Unauthorized"}}

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> post(request_path, %{"payment_method" => "pix"})
           |> json_response(422) == %{"errors" => %{"detail" => "Unprocessable Content"}}

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", "payment-unsupported-method")
           |> post(request_path, %{"payment_method" => "credit_card"})
           |> json_response(422) == %{"errors" => %{"detail" => "Unprocessable Content"}}
  end

  test "a malformed successful provider response is exposed as a bad gateway", %{conn: conn} do
    fixture = BillingFixtures.create!()
    configure_mercado_pago!(fixture)
    token = authenticate!(fixture)

    assert {:ok, order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture)
             )

    Req.Test.expect(MercadoPago, fn request ->
      request
      |> put_status(:created)
      |> Req.Test.json(%{id: "ORD-without-payment-action"})
    end)

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", "payment-malformed-provider")
           |> post(
             ~p"/api/v1/polos/#{fixture.polo_route.slug}/orders/#{order.id}/payment-intents",
             %{"payment_method" => "pix"}
           )
           |> json_response(502) == %{"errors" => %{"detail" => "Bad Gateway"}}
  end

  test "an authenticated Mercado Pago webhook settles the order and provisions the subscription",
       %{conn: conn} do
    fixture = BillingFixtures.create!()
    configure_mercado_pago!(fixture)
    token = authenticate!(fixture)

    assert {:ok, order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture)
             )

    provider_reference = "ORD01JQ4S4KY8HWQ6NA5PXB65B3D3"
    payment_reference = "PAY01JQ4S4KY8HWQ6NA5PXB65B3D4"
    occurred_at = DateTime.utc_now(:microsecond)

    Req.Test.expect(MercadoPago, 2, fn request ->
      case {request.method, request.request_path} do
        {"POST", "/v1/orders"} ->
          request
          |> put_status(:created)
          |> Req.Test.json(
            pix_order_response(order, provider_reference, payment_reference,
              status: "action_required"
            )
          )

        {"GET", "/v1/orders/" <> ^provider_reference} ->
          assert get_req_header(request, "authorization") == ["Bearer #{@access_token}"]

          Req.Test.json(
            request,
            pix_order_response(order, provider_reference, payment_reference,
              status: "processed",
              external_reference: "#{fixture.polo.id}_#{order.id}",
              occurred_at: occurred_at
            )
          )
      end
    end)

    assert {:ok, %{payment_intent: intent}} =
             Billing.start_payment(fixture.member_scope, %{
               order_id: order.id,
               payment_method: "pix",
               idempotency_key: "payment-webhook-001"
             })

    webhook_request_id = "2066ca19-c6f1-498a-be75-1923005edd06"
    notification_id = "123456789"
    signature = webhook_signature(provider_reference, webhook_request_id, @webhook_secret)
    query = URI.encode_query(%{"data.id" => provider_reference, "type" => "order"})

    webhook_body = %{
      "action" => "order.processed",
      "api_version" => "v1",
      "date_created" => DateTime.to_iso8601(occurred_at),
      "id" => notification_id,
      "live_mode" => false,
      "type" => "order",
      "data" => %{"id" => provider_reference}
    }

    assert conn
           |> put_req_header("x-request-id", webhook_request_id)
           |> put_req_header("x-signature", signature)
           |> post(
             "/api/v1/webhooks/mercado_pago/#{fixture.merchant_account.id}?#{query}",
             webhook_body
           )
           |> response(200) == ""

    order_history =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get(~p"/api/v1/polos/#{fixture.polo_route.slug}/me/orders")
      |> json_response(200)

    assert [%{"id" => order_id, "status" => "paid"}] = order_history["data"]
    assert order_id == order.id

    subscriptions =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get(~p"/api/v1/me/subscriptions")
      |> json_response(200)

    assert [subscription] = subscriptions["data"]
    assert subscription["status"] == "active"
    assert subscription["current_cycle"]["status"] == "active"

    wallet =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get(~p"/api/v1/polos/#{fixture.polo_route.slug}/me/vouchers")
      |> json_response(200)

    assert [_voucher | _rest] = wallet["data"]["vouchers"]
    assert intent.provider_reference == provider_reference

    assert {:ok, ^webhook_request_id} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               {:ok, repo.one!(PaymentProviderEvent).external_event_id}
             end)
  end

  test "a webhook recovers a capture created during an ambiguous payment-start timeout", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    configure_mercado_pago!(fixture)

    assert {:ok, order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture)
             )

    provider_reference = "ORD01JQ4S4KY8HWQ6NA5PXB65B3D3"
    payment_reference = "PAY01JQ4S4KY8HWQ6NA5PXB65B3D4"
    occurred_at = DateTime.utc_now(:microsecond)

    Req.Test.expect(MercadoPago, 2, fn request ->
      case {request.method, request.request_path} do
        {"POST", "/v1/orders"} ->
          Req.Test.transport_error(request, :timeout)

        {"GET", "/v1/orders/" <> ^provider_reference} ->
          Req.Test.json(
            request,
            pix_order_response(order, provider_reference, payment_reference,
              status: "processed",
              external_reference: "#{fixture.polo.id}_#{order.id}",
              occurred_at: occurred_at
            )
          )
      end
    end)

    assert {:error, :payment_gateway_unavailable} =
             Billing.start_payment(fixture.member_scope, %{
               order_id: order.id,
               payment_method: "pix",
               idempotency_key: "payment-ambiguous-timeout"
             })

    assert send_webhook(conn, fixture, provider_reference, "capture-after-timeout") == 200

    assert {:ok, %{rows: [["paid", "succeeded", 1, 1]]}} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               {:ok,
                repo.query!(
                  """
                  SELECT
                    orders.status,
                    payment_intents.status,
                    (SELECT count(*) FROM payments),
                    (SELECT count(*) FROM access_contracts)
                  FROM orders
                  JOIN payment_intents
                    ON payment_intents.polo_id = orders.polo_id
                   AND payment_intents.order_id = orders.id
                  WHERE orders.id = $1
                  """,
                  [Ecto.UUID.dump!(order.id)]
                )}
             end)
  end

  test "an expired Pix notification closes the intent and allows a new payment attempt", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    configure_mercado_pago!(fixture)

    assert {:ok, order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture)
             )

    first_provider_reference = "ORD01JQ4S4KY8HWQ6NA5PXB65B3D3"
    first_payment_reference = "PAY01JQ4S4KY8HWQ6NA5PXB65B3D4"

    Req.Test.expect(MercadoPago, fn request ->
      request
      |> put_status(:created)
      |> Req.Test.json(
        pix_order_response(order, first_provider_reference, first_payment_reference,
          status: "action_required"
        )
      )
    end)

    assert {:ok, %{payment_intent: first_intent}} =
             Billing.start_payment(fixture.member_scope, %{
               order_id: order.id,
               payment_method: "pix",
               idempotency_key: "payment-before-expiration"
             })

    Req.Test.expect(MercadoPago, fn request ->
      Req.Test.json(
        request,
        pix_order_response(order, first_provider_reference, first_payment_reference,
          status: "expired",
          external_reference: "#{fixture.polo.id}_#{order.id}"
        )
      )
    end)

    assert send_webhook(conn, fixture, first_provider_reference, "pix-expired") == 200

    Req.Test.expect(MercadoPago, fn request ->
      Req.Test.json(
        request,
        pix_order_response(order, first_provider_reference, first_payment_reference,
          status: "expired",
          external_reference: "#{fixture.polo.id}_#{order.id}"
        )
      )
    end)

    assert send_webhook(conn, fixture, first_provider_reference, "pix-still-expired") == 200

    assert {:ok, %{rows: [["awaiting_payment", "expired", %{}, 2, 1, 1]]}} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               {:ok,
                repo.query!(
                  """
                  SELECT
                    orders.status,
                    payment_intents.status,
                    payment_intents.next_action,
                    (SELECT count(*) FROM payment_provider_events),
                    (SELECT count(*) FROM domain_events WHERE event_type = 'payment_intent.expired'),
                    (SELECT count(*) FROM outbox_messages WHERE topic = 'billing.payment_intents.expired')
                  FROM orders
                  JOIN payment_intents
                    ON payment_intents.polo_id = orders.polo_id
                   AND payment_intents.order_id = orders.id
                  WHERE payment_intents.id = $1
                  """,
                  [Ecto.UUID.dump!(first_intent.id)]
                )}
             end)

    second_provider_reference = "ORD01JQ4S4KY8HWQ6NA5PXB65B3D5"
    second_payment_reference = "PAY01JQ4S4KY8HWQ6NA5PXB65B3D6"

    Req.Test.expect(MercadoPago, fn request ->
      request
      |> put_status(:created)
      |> Req.Test.json(
        pix_order_response(order, second_provider_reference, second_payment_reference,
          status: "action_required"
        )
      )
    end)

    assert {:ok, %{payment_intent: second_intent}} =
             Billing.start_payment(fixture.member_scope, %{
               order_id: order.id,
               payment_method: "pix",
               idempotency_key: "payment-after-expiration"
             })

    refute second_intent.id == first_intent.id
  end

  test "a later signed notification for the same capture is acknowledged without provisioning twice",
       %{conn: conn} do
    fixture = BillingFixtures.create!()
    configure_mercado_pago!(fixture)

    assert {:ok, order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture)
             )

    provider_reference = "ORD01JQ4S4KY8HWQ6NA5PXB65B3D3"
    payment_reference = "PAY01JQ4S4KY8HWQ6NA5PXB65B3D4"
    occurred_at = DateTime.utc_now(:microsecond)

    Req.Test.expect(MercadoPago, 3, fn request ->
      case {request.method, request.request_path} do
        {"POST", "/v1/orders"} ->
          request
          |> put_status(:created)
          |> Req.Test.json(
            pix_order_response(order, provider_reference, payment_reference,
              status: "action_required"
            )
          )

        {"GET", "/v1/orders/" <> ^provider_reference} ->
          Req.Test.json(
            request,
            pix_order_response(order, provider_reference, payment_reference,
              status: "processed",
              external_reference: "#{fixture.polo.id}_#{order.id}",
              occurred_at: occurred_at
            )
          )
      end
    end)

    assert {:ok, _payment} =
             Billing.start_payment(fixture.member_scope, %{
               order_id: order.id,
               payment_method: "pix",
               idempotency_key: "payment-later-notification"
             })

    assert send_webhook(conn, fixture, provider_reference, "notification-first") == 200
    assert send_webhook(conn, fixture, provider_reference, "notification-later") == 200

    assert {:ok, %{contracts: 1, events: 2, payments: 1}} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               {:ok,
                %{
                  contracts: repo.aggregate(AccessContract, :count),
                  events: repo.aggregate(PaymentProviderEvent, :count),
                  payments: repo.aggregate(Payment, :count)
                }}
             end)
  end

  test "an invalid webhook signature is rejected before fetching provider data", %{conn: conn} do
    fixture = BillingFixtures.create!()
    configure_mercado_pago!(fixture)
    attach_webhook_rejection_handler!()

    assert {:ok, order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture)
             )

    provider_reference = "ORD01JQ4S4KY8HWQ6NA5PXB65B3D3"
    payment_reference = "PAY01JQ4S4KY8HWQ6NA5PXB65B3D4"

    Req.Test.expect(MercadoPago, fn request ->
      request
      |> put_status(:created)
      |> Req.Test.json(
        pix_order_response(order, provider_reference, payment_reference,
          status: "action_required"
        )
      )
    end)

    assert {:ok, _payment} =
             Billing.start_payment(fixture.member_scope, %{
               order_id: order.id,
               payment_method: "pix",
               idempotency_key: "payment-invalid-webhook"
             })

    webhook_request_id = "2066ca19-c6f1-498a-be75-1923005edd06"
    query = URI.encode_query(%{"data.id" => provider_reference, "type" => "order"})

    assert conn
           |> put_req_header("x-request-id", webhook_request_id)
           |> put_req_header("x-signature", "ts=1742505638683,v1=#{String.duplicate("0", 64)}")
           |> post(
             "/api/v1/webhooks/mercado-pago/#{fixture.merchant_account.id}?#{query}",
             %{
               "action" => "order.processed",
               "id" => "invalid-signature-event",
               "type" => "order",
               "data" => %{"id" => provider_reference}
             }
           )
           |> json_response(401) == %{"errors" => %{"detail" => "Unauthorized"}}

    assert_receive {:webhook_rejected, %{count: 1}, metadata}
    assert metadata.provider == "mercado_pago"
    assert metadata.merchant_account_id == fixture.merchant_account.id
    assert metadata.reason == :webhook_unauthorized
  end

  test "a webhook whose signed query and body identify different orders is rejected before fetch",
       %{conn: conn} do
    fixture = BillingFixtures.create!()
    configure_mercado_pago!(fixture)
    provider_reference = "ORD01JQ4S4KY8HWQ6NA5PXB65B3D3"
    provider_request_id = Ecto.UUID.generate()
    signature = webhook_signature(provider_reference, provider_request_id, @webhook_secret)
    query = URI.encode_query(%{"data.id" => provider_reference, "type" => "order"})

    assert conn
           |> put_req_header("x-request-id", provider_request_id)
           |> put_req_header("x-signature", signature)
           |> post(
             "/api/v1/webhooks/mercado-pago/#{fixture.merchant_account.id}?#{query}",
             %{
               "action" => "order.processed",
               "id" => "mismatched-notification",
               "type" => "order",
               "data" => %{"id" => "ORD01JQ4S4KY8HWQ6NA5PXB65B3D9"}
             }
           )
           |> json_response(400) == %{"errors" => %{"detail" => "Bad Request"}}
  end

  defp configure_mercado_pago!(fixture) do
    fixture.provider
    |> Ecto.Changeset.change(code: "mercado_pago")
    |> Clubeira.Repo.update!()

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

  defp attach_webhook_rejection_handler! do
    handler_id = "payment-webhook-rejected-#{System.unique_integer([:positive])}"
    test_process = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:clubeira, :billing, :webhook_rejected],
        fn _event, measurements, metadata, _config ->
          send(test_process, {:webhook_rejected, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp authenticate!(fixture) do
    assert {:ok, _credential} = Accounts.set_password(fixture.user, @password)
    assert {:ok, session} = Accounts.login(fixture.user.email, @password)
    session.token
  end

  defp pix_order_response(order, provider_reference, payment_reference, options) do
    status = Keyword.fetch!(options, :status)

    status_detail =
      case status do
        "processed" -> "accredited"
        "expired" -> "expired"
        "cancelled" -> "cancelled"
        "failed" -> "failed"
        _other -> "waiting_transfer"
      end

    payment = %{
      id: payment_reference,
      status: status,
      status_detail: status_detail,
      amount: Decimal.to_string(order.total_amount),
      payment_method: %{
        id: "pix",
        type: "bank_transfer",
        ticket_url: "https://www.mercadopago.com.br/sandbox/payments/example/ticket",
        qr_code: "000201010212example-pix-code",
        qr_code_base64: "ignored"
      }
    }

    %{
      id: provider_reference,
      type: "online",
      status: status,
      status_detail: payment.status_detail,
      total_amount: Decimal.to_string(order.total_amount),
      currency: order.currency,
      external_reference: Keyword.get(options, :external_reference, order.id),
      last_updated_date:
        options
        |> Keyword.get(:occurred_at, DateTime.utc_now(:microsecond))
        |> DateTime.to_iso8601(),
      transactions: %{payments: [payment]}
    }
  end

  defp webhook_signature(data_id, request_id, secret) do
    timestamp = System.system_time(:millisecond) |> Integer.to_string()
    manifest = "id:#{data_id};request-id:#{request_id};ts:#{timestamp};"

    digest =
      :crypto.mac(:hmac, :sha256, secret, manifest)
      |> Base.encode16(case: :lower)

    "ts=#{timestamp},v1=#{digest}"
  end

  defp send_webhook(conn, fixture, provider_reference, event_id) do
    provider_request_id = Ecto.UUID.generate()
    signature = webhook_signature(provider_reference, provider_request_id, @webhook_secret)
    query = URI.encode_query(%{"data.id" => provider_reference, "type" => "order"})

    conn
    |> put_req_header("x-request-id", provider_request_id)
    |> put_req_header("x-signature", signature)
    |> post(
      "/api/v1/webhooks/mercado-pago/#{fixture.merchant_account.id}?#{query}",
      %{
        "action" => "order.processed",
        "id" => event_id,
        "type" => "order",
        "data" => %{"id" => provider_reference}
      }
    )
    |> Map.fetch!(:status)
  end
end
