defmodule ClubeiraWeb.Platform.BillingControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  import Ecto.Query

  alias Clubeira.Accounts
  alias Clubeira.Audit.SystemEvent
  alias Clubeira.Audit.TenantEvent
  alias Clubeira.Billing.Gateways.MercadoPago
  alias Clubeira.BillingFixtures
  alias Clubeira.Events.DomainEvent
  alias Clubeira.Events.OutboxMessage
  alias Clubeira.Factory
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  @password "uma-senha-forte-para-billing-da-plataforma"
  @access_token "test-platform-billing-access-token"
  @webhook_secret "test-platform-billing-webhook-secret-32-bytes-minimum"
  @back_url "https://clubeira.test/platform-billing/return"

  test "platform plan publication, polo subscription and recurring invoice work end-to-end", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    admin_scope = grant_polo_admin!(fixture)
    admin = Repo.get!(Clubeira.Accounts.User, admin_scope.actor_user_id)
    grant_platform_billing_admin!(admin)
    token = authenticate!(admin)
    platform_account = configure_platform_gateway!(fixture)

    code = "operacao-#{uuid7()}"
    now = DateTime.utc_now(:microsecond)

    plan_attributes = %{
      "name" => "Operação",
      "version_name" => "Operação 2026",
      "description" => "Plano operacional para polos em crescimento.",
      "features" => [
        %{
          "key" => "unlimited_members",
          "name" => "Membros ilimitados",
          "value_kind" => "boolean",
          "boolean_value" => true
        },
        %{
          "key" => "partner_limit",
          "name" => "Limite de parceiros",
          "value_kind" => "integer",
          "integer_value" => 250
        }
      ],
      "price" => %{
        "currency" => "BRL",
        "amount" => "399.90",
        "billing_interval_unit" => "month",
        "billing_interval_count" => 1,
        "valid_from" => DateTime.to_iso8601(DateTime.add(now, -60)),
        "valid_until" => DateTime.to_iso8601(DateTime.add(now, 31_536_000))
      }
    }

    first_plan =
      conn
      |> bearer(token)
      |> put("/api/v1/platform/billing/plans/#{code}/versions/1", plan_attributes)
      |> json_response(200)

    assert %{
             "data" => %{
               "code" => ^code,
               "status" => "active",
               "version" => %{
                 "version" => 1,
                 "status" => "published",
                 "features" => features,
                 "price" => %{
                   "currency" => "BRL",
                   "amount" => "399.90",
                   "billing_interval_unit" => "month",
                   "billing_interval_count" => 1
                 }
               }
             }
           } = first_plan

    assert Enum.map(features, & &1["key"]) == ["partner_limit", "unlimited_members"]

    assert conn
           |> recycle()
           |> bearer(token)
           |> put("/api/v1/platform/billing/plans/#{code}/versions/1", plan_attributes)
           |> json_response(200) == first_plan

    assert %{"data" => [listed_plan]} =
             conn
             |> recycle()
             |> bearer(token)
             |> get("/api/v1/platform/billing/plans")
             |> json_response(200)

    assert listed_plan["code"] == code
    platform_price_id = get_in(first_plan, ["data", "version", "price", "id"])
    parent = self()
    provider_subscription_reference = "PREAPPROVAL-#{uuid7()}"

    Req.Test.expect(MercadoPago, fn request ->
      assert request.method == "POST"
      assert request.request_path == "/preapproval"
      assert Plug.Conn.get_req_header(request, "authorization") == ["Bearer #{@access_token}"]
      assert [provider_idempotency_key] = Plug.Conn.get_req_header(request, "x-idempotency-key")
      assert {:ok, _subscription_id} = Ecto.UUID.cast(provider_idempotency_key)
      assert {:ok, body, request} = Plug.Conn.read_body(request)
      payload = Jason.decode!(body)
      send(parent, {:platform_external_reference, payload["external_reference"]})

      request
      |> Plug.Conn.put_status(:created)
      |> Req.Test.json(%{
        id: provider_subscription_reference,
        external_reference: payload["external_reference"],
        status: "pending",
        init_point: "https://www.mercadopago.com.br/subscriptions/checkout",
        auto_recurring: %{
          frequency: 1,
          frequency_type: "months",
          transaction_amount: "399.90",
          currency_id: "BRL"
        },
        next_payment_date: DateTime.to_iso8601(DateTime.add(now, 2_592_000))
      })
    end)

    subscription_response =
      conn
      |> recycle()
      |> bearer(token)
      |> post(
        "/api/v1/polos/#{fixture.polo_route.slug}/backoffice/platform-subscription",
        %{
          "platform_price_id" => platform_price_id,
          "idempotency_key" => "platform-subscription-001"
        }
      )
      |> json_response(200)

    assert %{
             "data" => %{
               "provider" => "mercado_pago",
               "subscription" => %{
                 "id" => subscription_id,
                 "status" => "pending",
                 "next_action" => %{
                   "type" => "redirect",
                   "url" => "https://www.mercadopago.com.br/subscriptions/checkout"
                 }
               }
             }
           } = subscription_response

    assert_receive {:platform_external_reference, external_reference}
    assert external_reference == "platform:#{fixture.polo.id}:#{subscription_id}"

    provider_invoice_reference = "AUTHORIZED-#{uuid7()}"
    provider_payment_reference = "PLATFORM-PAYMENT-#{uuid7()}"
    captured_at = DateTime.utc_now(:microsecond)

    Req.Test.expect(MercadoPago, fn request ->
      assert request.method == "GET"
      assert request.request_path == "/authorized_payments/#{provider_invoice_reference}"

      Req.Test.json(request, %{
        id: provider_invoice_reference,
        preapproval_id: provider_subscription_reference,
        external_reference: external_reference,
        currency_id: "BRL",
        transaction_amount: "399.90",
        last_modified: DateTime.to_iso8601(captured_at),
        payment: %{
          id: provider_payment_reference,
          status: "approved",
          status_detail: "accredited"
        }
      })
    end)

    assert send_invoice_webhook(
             conn,
             platform_account,
             provider_invoice_reference,
             captured_at
           ) == 200

    Req.Test.expect(MercadoPago, fn request ->
      assert request.request_path == "/authorized_payments/#{provider_invoice_reference}"

      Req.Test.json(request, %{
        id: provider_invoice_reference,
        preapproval_id: provider_subscription_reference,
        external_reference: external_reference,
        currency_id: "BRL",
        transaction_amount: "399.90",
        last_modified: DateTime.to_iso8601(captured_at),
        payment: %{
          id: provider_payment_reference,
          status: "approved",
          status_detail: "accredited"
        }
      })
    end)

    assert send_invoice_webhook(
             conn,
             platform_account,
             provider_invoice_reference,
             captured_at
           ) == 200

    mismatched_invoice_reference = "AUTHORIZED-MISMATCH-#{uuid7()}"

    Req.Test.expect(MercadoPago, fn request ->
      assert request.request_path == "/authorized_payments/#{mismatched_invoice_reference}"

      Req.Test.json(request, %{
        id: mismatched_invoice_reference,
        preapproval_id: provider_subscription_reference,
        external_reference: external_reference,
        currency_id: "BRL",
        transaction_amount: "1.00",
        last_modified: DateTime.to_iso8601(captured_at),
        payment: %{
          id: "PLATFORM-MISMATCH-#{uuid7()}",
          status: "approved",
          status_detail: "accredited"
        }
      })
    end)

    assert send_invoice_webhook(
             conn,
             platform_account,
             mismatched_invoice_reference,
             captured_at
           ) == 422

    assert %{
             "data" => %{
               "subscription" => %{
                 "id" => ^subscription_id,
                 "status" => "active",
                 "plan" => %{
                   "code" => ^code,
                   "version" => 1,
                   "features" => read_features
                 },
                 "current_period" => %{"starts_at" => _, "ends_at" => _}
               },
               "invoices" => [
                 %{
                   "status" => "paid",
                   "currency" => "BRL",
                   "total_amount" => "399.90",
                   "items" => [
                     %{
                       "item_kind" => "plan",
                       "quantity" => 1,
                       "total_amount" => "399.90"
                     }
                   ],
                   "payment" => %{
                     "status" => "succeeded",
                     "amount" => "399.90"
                   }
                 }
               ]
             }
           } =
             conn
             |> recycle()
             |> bearer(token)
             |> get("/api/v1/polos/#{fixture.polo_route.slug}/backoffice/platform-billing")
             |> json_response(200)

    assert Enum.map(read_features, & &1["key"]) == ["partner_limit", "unlimited_members"]

    assert Repo.aggregate(Clubeira.Platform.Plan, :count) == 1
    assert Repo.aggregate(Clubeira.Platform.PlanVersion, :count) == 1
    assert Repo.aggregate(Clubeira.Platform.Feature, :count) == 2
    assert Repo.aggregate(Clubeira.Platform.PlanVersionFeature, :count) == 2
    assert Repo.aggregate(Clubeira.Platform.Price, :count) == 1

    assert Repo.aggregate(
             from(event in SystemEvent,
               where: event.action == "platform_plan_version.published"
             ),
             :count
           ) == 1

    assert {:ok, :verified} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               assert repo.aggregate(Clubeira.Platform.PoloSubscription, :count) == 1
               assert repo.aggregate(Clubeira.Platform.Invoice, :count) == 1
               assert repo.aggregate(Clubeira.Platform.InvoiceItem, :count) == 1
               assert repo.aggregate(Clubeira.Platform.Payment, :count) == 1

               event =
                 repo.get_by!(DomainEvent,
                   aggregate_type: "platform_invoice",
                   event_type: "platform_invoice.paid"
                 )

               assert repo.get_by!(OutboxMessage, domain_event_id: event.id).topic ==
                        "platform.billing.invoices.paid"

               assert repo.get_by!(TenantEvent,
                        action: "platform_invoice.paid",
                        resource_id: event.aggregate_id
                      )

               {:ok, :verified}
             end)
  end

  test "future plan prices can be published and replayed without entering the current catalog", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    admin_scope = grant_polo_admin!(fixture)
    admin = Repo.get!(Clubeira.Accounts.User, admin_scope.actor_user_id)
    grant_platform_billing_admin!(admin)
    token = authenticate!(admin)
    code = "futuro-#{uuid7()}"
    now = DateTime.utc_now(:microsecond)

    attributes = %{
      "name" => "Plano futuro",
      "version_name" => "Plano futuro 2027",
      "description" => "Preço publicado hoje com vigência comercial futura.",
      "features" => [
        %{
          "key" => "partner_limit_future",
          "name" => "Limite futuro de parceiros",
          "value_kind" => "integer",
          "integer_value" => 500
        }
      ],
      "price" => %{
        "currency" => "BRL",
        "amount" => "499.90",
        "billing_interval_unit" => "month",
        "billing_interval_count" => 1,
        "valid_from" => DateTime.to_iso8601(DateTime.add(now, 86_400)),
        "valid_until" => DateTime.to_iso8601(DateTime.add(now, 31_622_400))
      }
    }

    first =
      conn
      |> bearer(token)
      |> put("/api/v1/platform/billing/plans/#{code}/versions/1", attributes)
      |> json_response(200)

    assert get_in(first, ["data", "code"]) == code

    assert conn
           |> recycle()
           |> bearer(token)
           |> put("/api/v1/platform/billing/plans/#{code}/versions/1", attributes)
           |> json_response(200) == first

    assert %{"data" => []} =
             conn
             |> recycle()
             |> bearer(token)
             |> get("/api/v1/platform/billing/plans")
             |> json_response(200)
  end

  test "platform plan catalog requires a current platform billing role even when populated", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    publisher_scope = grant_polo_admin!(fixture)
    publisher = Repo.get!(Clubeira.Accounts.User, publisher_scope.actor_user_id)
    grant_platform_billing_admin!(publisher)
    publisher_token = authenticate!(publisher)
    unauthorized_token = authenticate!(fixture.user)
    code = "restricted-catalog-#{uuid7()}"

    assert %{"data" => %{"code" => ^code}} =
             conn
             |> bearer(publisher_token)
             |> put(
               "/api/v1/platform/billing/plans/#{code}/versions/1",
               boundary_plan_attributes(DateTime.utc_now(:microsecond))
             )
             |> json_response(200)

    assert %{"errors" => %{"code" => "platform_billing_admin_required"}} =
             conn
             |> recycle()
             |> bearer(unauthorized_token)
             |> get("/api/v1/platform/billing/plans")
             |> json_response(403)
  end

  test "platform billing boundaries reject unauthorized, gapped and conflicting operations", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    admin_scope = grant_polo_admin!(fixture)
    admin = Repo.get!(Clubeira.Accounts.User, admin_scope.actor_user_id)
    admin_token = authenticate!(admin)
    member_token = authenticate!(fixture.user)
    code = "boundary-#{uuid7()}"
    now = DateTime.utc_now(:microsecond)
    attributes = boundary_plan_attributes(now)

    assert %{"errors" => %{"code" => "platform_billing_admin_required"}} =
             conn
             |> bearer(admin_token)
             |> get("/api/v1/platform/billing/plans")
             |> json_response(403)

    assert %{"errors" => %{"code" => "platform_billing_admin_required"}} =
             conn
             |> recycle()
             |> bearer(admin_token)
             |> put("/api/v1/platform/billing/plans/#{code}/versions/1", attributes)
             |> json_response(403)

    grant_platform_billing_admin!(admin)

    assert %{"data" => %{"subscription" => nil, "invoices" => []}} =
             conn
             |> recycle()
             |> bearer(admin_token)
             |> get("/api/v1/polos/#{fixture.polo_route.slug}/backoffice/platform-billing")
             |> json_response(200)

    assert %{"errors" => %{"code" => "billing_admin_required"}} =
             conn
             |> recycle()
             |> bearer(member_token)
             |> get("/api/v1/polos/#{fixture.polo_route.slug}/backoffice/platform-billing")
             |> json_response(403)

    assert %{"errors" => %{"code" => "invalid_platform_plan_identity"}} =
             conn
             |> recycle()
             |> bearer(admin_token)
             |> put("/api/v1/platform/billing/plans/#{code}/versions/0", attributes)
             |> json_response(422)

    assert %{"errors" => %{"code" => "platform_plan_version_gap"}} =
             conn
             |> recycle()
             |> bearer(admin_token)
             |> put("/api/v1/platform/billing/plans/#{code}/versions/2", attributes)
             |> json_response(409)

    first =
      conn
      |> recycle()
      |> bearer(admin_token)
      |> put("/api/v1/platform/billing/plans/#{code}/versions/1", attributes)

    assert %{"data" => %{"code" => ^code}} = json_response(first, 200)

    assert %{"errors" => %{"code" => "platform_plan_version_conflict"}} =
             conn
             |> recycle()
             |> bearer(admin_token)
             |> put("/api/v1/platform/billing/plans/#{code}/versions/1", %{
               attributes
               | "description" => "Conteúdo divergente para uma versão imutável."
             })
             |> json_response(409)

    assert %{"errors" => %{"detail" => "Not Found"}} =
             conn
             |> recycle()
             |> bearer(admin_token)
             |> post(
               "/api/v1/polos/#{fixture.polo_route.slug}/backoffice/platform-subscription",
               %{
                 "platform_price_id" => uuid7(),
                 "idempotency_key" => "missing-platform-price"
               }
             )
             |> json_response(404)
  end

  defp grant_polo_admin!(fixture) do
    ReviewsFixtures.grant_moderator!(
      %{ids: %{polo: fixture.polo.id}, scope: fixture.service_scope},
      role_key: "admin"
    )
  end

  defp grant_platform_billing_admin!(user) do
    now = DateTime.utc_now(:microsecond)

    organization =
      Factory.insert(:organization,
        kind: "platform",
        legal_name: "Clubeira Plataforma",
        trade_name: "Clubeira",
        status: "active"
      )

    role =
      Factory.insert(:organization_role,
        organization_id: organization.id,
        key: "platform_billing_admin",
        name: "Administração de billing da plataforma",
        status: "active"
      )

    membership =
      Factory.insert(:organization_membership,
        organization_id: organization.id,
        user_id: user.id,
        valid_during: Factory.tstz_range(DateTime.add(now, -60)),
        status: "active"
      )

    Factory.insert(:organization_membership_role,
      organization_id: organization.id,
      organization_membership_id: membership.id,
      organization_role_id: role.id,
      inserted_at: now
    )
  end

  defp authenticate!(user) do
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session.token
  end

  defp configure_platform_gateway!(fixture) do
    fixture.provider
    |> Ecto.Changeset.change(code: "mercado_pago")
    |> Repo.update!()

    account =
      Factory.insert(:merchant_account,
        payment_provider: fixture.provider,
        kind: "platform",
        name: "Clubeira SaaS",
        provider_account_reference: "platform-#{uuid7()}"
      )

    previous_gateway = Application.get_env(:clubeira, MercadoPago)
    previous_billing = Application.get_env(:clubeira, :platform_billing)

    Application.put_env(:clubeira, MercadoPago,
      accounts: %{
        account.provider_account_reference => %{
          access_token: @access_token,
          webhook_secret: @webhook_secret
        }
      },
      subscription_back_url: @back_url,
      req_options: [plug: {Req.Test, MercadoPago}]
    )

    Application.put_env(:clubeira, :platform_billing, merchant_account_id: account.id)

    on_exit(fn ->
      restore_env(MercadoPago, previous_gateway)
      restore_env(:platform_billing, previous_billing)
    end)

    account
  end

  defp send_invoice_webhook(conn, account, reference, occurred_at) do
    provider_request_id = uuid7()
    signature = webhook_signature(reference, provider_request_id)

    query =
      URI.encode_query(%{"data.id" => reference, "type" => "subscription_authorized_payment"})

    conn
    |> recycle()
    |> put_req_header("x-request-id", provider_request_id)
    |> put_req_header("x-signature", signature)
    |> post(
      "/api/v1/webhooks/mercado-pago/#{account.id}?#{query}",
      %{
        "action" => "subscription_authorized_payment.created",
        "date_created" => DateTime.to_iso8601(occurred_at),
        "type" => "subscription_authorized_payment",
        "data" => %{"id" => reference}
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

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp boundary_plan_attributes(now) do
    %{
      "name" => "Plano de fronteira",
      "version_name" => "Fronteira 2026",
      "description" => "Plano usado para validar contratos públicos e imutabilidade.",
      "features" => [
        %{
          "key" => "boundary_feature",
          "name" => "Feature de fronteira",
          "value_kind" => "boolean",
          "boolean_value" => true
        }
      ],
      "price" => %{
        "currency" => "BRL",
        "amount" => "99.90",
        "billing_interval_unit" => "month",
        "billing_interval_count" => 1,
        "valid_from" => DateTime.to_iso8601(DateTime.add(now, -60)),
        "valid_until" => DateTime.to_iso8601(DateTime.add(now, 31_536_000))
      }
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:clubeira, key)
  defp restore_env(key, value), do: Application.put_env(:clubeira, key, value)
  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
