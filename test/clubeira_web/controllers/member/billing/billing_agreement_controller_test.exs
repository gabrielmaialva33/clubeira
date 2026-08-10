defmodule ClubeiraWeb.Member.BillingAgreementControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  import Ecto.Query

  alias Clubeira.Accounts
  alias Clubeira.Billing
  alias Clubeira.Billing.Gateways.MercadoPago
  alias Clubeira.BillingFixtures
  alias Clubeira.Repo
  alias Clubeira.Subscriptions.ProductOfferingVersion

  @password "uma-senha-forte-para-recorrencia"
  @access_token "test-access-token"
  @webhook_secret "test-webhook-secret-with-at-least-32-bytes"

  setup do
    previous = Application.get_env(:clubeira, MercadoPago)

    Application.put_env(:clubeira, MercadoPago,
      accounts: %{
        "test-merchant-account" => %{
          access_token: @access_token,
          webhook_secret: @webhook_secret
        }
      },
      subscription_back_url: "https://app.clubeira.test/assinatura/retorno",
      req_options: [plug: {Req.Test, MercadoPago}]
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:clubeira, MercadoPago, previous),
        else: Application.delete_env(:clubeira, MercadoPago)
    end)

    :ok
  end

  test "a member starts one durable automatic billing agreement for their order", %{conn: conn} do
    fixture = BillingFixtures.create!()
    configure_account!(fixture)
    make_automatic!(fixture)
    token = authenticate!(fixture)

    assert {:ok, order} =
             Billing.place_order(fixture.member_scope, BillingFixtures.checkout_request(fixture))

    provider_reference = "2c938084726fca480172750000000001"
    redirect_url = "https://www.mercadopago.com.br/subscriptions/checkout?preapproval_id=abc"

    Req.Test.expect(MercadoPago, fn request ->
      assert request.method == "POST"
      assert request.request_path == "/preapproval"
      assert get_req_header(request, "authorization") == ["Bearer #{@access_token}"]
      assert [_stable_idempotency_key] = get_req_header(request, "x-idempotency-key")

      {:ok, body, request} = read_body(request)

      assert %{
               "reason" => reason,
               "external_reference" => external_reference,
               "payer_email" => payer_email,
               "back_url" => "https://app.clubeira.test/assinatura/retorno",
               "auto_recurring" => %{
                 "frequency" => 1,
                 "frequency_type" => "months",
                 "transaction_amount" => amount,
                 "currency_id" => "BRL"
               }
             } = Jason.decode!(body)

      assert reason == fixture.offering_version.name
      assert external_reference == "#{fixture.polo.id}_#{order.id}"
      assert payer_email == fixture.user.email
      assert Decimal.equal?(Decimal.new(amount), order.total_amount)

      request
      |> put_status(:created)
      |> Req.Test.json(%{
        id: provider_reference,
        external_reference: external_reference,
        init_point: redirect_url,
        status: "pending",
        next_payment_date: nil,
        auto_recurring: %{
          frequency: 1,
          frequency_type: "months",
          transaction_amount: Decimal.to_string(order.total_amount),
          currency_id: "BRL"
        }
      })
    end)

    path =
      ~p"/api/v1/polos/#{fixture.polo_route.slug}/orders/#{order.id}/billing-agreements"

    first =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("idempotency-key", "automatic-subscription-start")
      |> post(path, %{})
      |> json_response(201)

    assert %{
             "data" => %{
               "id" => agreement_id,
               "order_id" => order_id,
               "product_offering_version_id" => offering_version_id,
               "provider" => "mercado_pago",
               "status" => "pending",
               "next_charge_at" => nil,
               "next_action" => %{"type" => "redirect", "url" => ^redirect_url}
             }
           } = first

    assert order_id == order.id
    assert offering_version_id == fixture.offering_version.id

    replayed =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("idempotency-key", "automatic-subscription-start")
      |> post(path, %{})
      |> json_response(201)

    assert replayed == first

    assert {:ok, %{rows: [[^provider_reference, 1, 1, 1]]}} =
             Repo.transact_in_polo(fixture.member_scope, fn repo ->
               {:ok,
                repo.query!(
                  """
                  SELECT
                    provider_reference,
                    (SELECT count(*) FROM domain_events
                     WHERE aggregate_type = 'billing_agreement' AND aggregate_id = $1),
                    (SELECT count(*) FROM tenant_audit_events
                     WHERE resource_type = 'billing_agreement' AND resource_id = $1),
                    (SELECT count(*) FROM outbox_messages AS message
                     JOIN domain_events AS event ON event.id = message.domain_event_id
                     WHERE event.aggregate_type = 'billing_agreement' AND event.aggregate_id = $1)
                  FROM billing_agreements
                  WHERE id = $1
                  """,
                  [Ecto.UUID.dump!(agreement_id)]
                )}
             end)

    provider_invoice_reference = "6114264375"
    provider_payment_reference = 19_951_521_071
    occurred_at = DateTime.utc_now(:microsecond)

    Req.Test.expect(MercadoPago, fn request ->
      assert request.method == "GET"
      assert request.request_path == "/authorized_payments/#{provider_invoice_reference}"

      Req.Test.json(request, %{
        id: String.to_integer(provider_invoice_reference),
        type: "scheduled",
        date_created: DateTime.to_iso8601(occurred_at),
        last_modified: DateTime.to_iso8601(occurred_at),
        preapproval_id: provider_reference,
        external_reference: "#{fixture.polo.id}_#{order.id}",
        currency_id: order.currency,
        transaction_amount: Decimal.to_string(order.total_amount),
        debit_date: DateTime.to_iso8601(occurred_at),
        status: "processed",
        summarized: "approved",
        payment: %{
          id: provider_payment_reference,
          status: "approved",
          status_detail: "accredited"
        }
      })
    end)

    provider_request_id = Ecto.UUID.generate()
    signature = webhook_signature(provider_invoice_reference, provider_request_id)

    query =
      URI.encode_query(%{
        "data.id" => provider_invoice_reference,
        "type" => "subscription_authorized_payment"
      })

    assert conn
           |> recycle()
           |> put_req_header("x-request-id", provider_request_id)
           |> put_req_header("x-signature", signature)
           |> post(
             "/api/v1/webhooks/mercado-pago/#{fixture.merchant_account.id}?#{query}",
             %{
               "action" => "updated",
               "type" => "subscription_authorized_payment",
               "data" => %{"id" => provider_invoice_reference}
             }
           )
           |> response(200) == ""

    assert {:ok, %{rows: [["active", "paid", "paid", true, 1, 1, 1]]}} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               {:ok,
                repo.query!(
                  """
                  SELECT
                    agreements.status,
                    invoices.status,
                    orders.status,
                    contracts.billing_agreement_id = agreements.id,
                    (SELECT count(*) FROM payments),
                    (SELECT count(*) FROM benefit_cycles),
                    (SELECT count(*) FROM payment_provider_events)
                  FROM billing_agreements AS agreements
                  JOIN consumer_invoices AS invoices
                    ON invoices.billing_agreement_id = agreements.id
                  JOIN orders ON orders.id = invoices.order_id
                  JOIN access_contracts AS contracts
                    ON contracts.billing_agreement_id = agreements.id
                  WHERE agreements.id = $1
                  """,
                  [Ecto.UUID.dump!(agreement_id)]
                )}
             end)

    assert %{
             "data" => %{
               "agreements" => [
                 %{
                   "id" => ^agreement_id,
                   "status" => "active",
                   "order" => %{"id" => ^order_id},
                   "product_offering_version" => %{
                     "id" => ^offering_version_id,
                     "name" => _name
                   },
                   "invoices" => [
                     %{
                       "status" => "paid",
                       "currency" => "BRL",
                       "total_amount" => invoice_amount,
                       "paid_at" => paid_at
                     } = invoice_data
                   ]
                 } = agreement_data
               ]
             }
           } =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> get("/api/v1/polos/#{fixture.polo_route.slug}/me/billing")
             |> json_response(200)

    assert Decimal.equal?(Decimal.new(invoice_amount), order.total_amount)
    assert {:ok, _paid_at, 0} = DateTime.from_iso8601(paid_at)
    refute Map.has_key?(agreement_data, "provider_reference")
    refute Map.has_key?(agreement_data, "merchant_account_id")
    refute Map.has_key?(agreement_data, "idempotency_key")
    refute Map.has_key?(agreement_data, "request_sha256")
    refute Map.has_key?(invoice_data, "provider_reference")
    refute Map.has_key?(invoice_data, "merchant_account_id")

    other_user = Clubeira.Factory.insert(:user)
    assert {:ok, _credential} = Accounts.set_password(other_user, @password)
    assert {:ok, other_session} = Accounts.login(other_user.email, @password)

    assert %{"data" => %{"agreements" => []}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{other_session.token}")
             |> get("/api/v1/polos/#{fixture.polo_route.slug}/me/billing")
             |> json_response(200)
  end

  test "billing agreement creation rejects ineligible orders before provider I/O", %{conn: conn} do
    fixture = BillingFixtures.create!()
    token = authenticate!(fixture)

    assert {:ok, order} =
             Billing.place_order(fixture.member_scope, BillingFixtures.checkout_request(fixture))

    path =
      ~p"/api/v1/polos/#{fixture.polo_route.slug}/orders/#{order.id}/billing-agreements"

    assert %{"errors" => %{"detail" => "Unprocessable Content"}} =
             conn
             |> put_req_header("authorization", "Bearer #{token}")
             |> post(path, %{})
             |> json_response(422)

    assert %{"errors" => %{"detail" => "Unprocessable Content"}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> put_req_header("idempotency-key", "non-automatic-agreement")
             |> post(path, %{})
             |> json_response(422)

    assert %{"errors" => %{"detail" => "Not Found"}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> put_req_header("idempotency-key", "missing-order-agreement")
             |> post(
               ~p"/api/v1/polos/#{fixture.polo_route.slug}/orders/#{Ecto.UUID.generate()}/billing-agreements",
               %{}
             )
             |> json_response(404)

    make_automatic!(fixture)

    assert %{"errors" => %{"detail" => "Service Unavailable"}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> put_req_header("idempotency-key", "unavailable-gateway-agreement")
             |> post(path, %{})
             |> json_response(503)
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

  defp configure_account!(fixture) do
    fixture.provider
    |> Ecto.Changeset.change(code: "mercado_pago")
    |> Repo.update!()

    options = Application.fetch_env!(:clubeira, MercadoPago)

    Application.put_env(
      :clubeira,
      MercadoPago,
      Keyword.put(options, :accounts, %{
        fixture.merchant_account.provider_account_reference => %{
          access_token: @access_token,
          webhook_secret: @webhook_secret
        }
      })
    )
  end

  defp authenticate!(fixture) do
    assert {:ok, _credential} = Accounts.set_password(fixture.user, @password)
    assert {:ok, session} = Accounts.login(fixture.user.email, @password)
    session.token
  end

  defp webhook_signature(data_id, request_id) do
    timestamp = System.system_time(:millisecond) |> Integer.to_string()
    manifest = "id:#{data_id};request-id:#{request_id};ts:#{timestamp};"

    digest =
      :crypto.mac(:hmac, :sha256, @webhook_secret, manifest)
      |> Base.encode16(case: :lower)

    "ts=#{timestamp},v1=#{digest}"
  end
end
