defmodule Clubeira.E2E.MemberCheckoutTest do
  use Clubeira.DataCase, async: false

  import Swoosh.TestAssertions

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Billing.Gateways.MercadoPago
  alias Clubeira.BillingFixtures
  alias Clubeira.Directory.Place
  alias Clubeira.Factory
  alias Clubeira.LegalFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  @password "uma-senha-forte-para-e2e-http"
  @access_token "e2e-mercado-pago-access-token"
  @webhook_secret "e2e-webhook-secret-with-at-least-32-bytes"

  setup {Req.Test, :set_req_test_from_context}
  setup {Req.Test, :verify_on_exit!}
  setup :set_swoosh_global

  setup do
    server =
      start_supervised!({
        Bandit,
        plug: ClubeiraWeb.Endpoint,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false,
        thousand_island_options: [num_acceptors: 2]
      })

    assert {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    {:ok, base_url: "http://127.0.0.1:#{port}"}
  end

  test "member checkout settles through an authenticated Pix webhook over the real HTTP stack", %{
    base_url: base_url
  } do
    fixture = BillingFixtures.create!()
    terms = LegalFixtures.registration_terms!()

    assert %Req.Response{
             status: 200,
             body: %{"service" => "clubeira", "status" => "ok"}
           } = Req.get!("#{base_url}/health", retry: false)

    assert %Req.Response{
             status: 201,
             body: %{
               "data" => %{
                 "access_token" => token,
                 "token_type" => "Bearer",
                 "user" => %{
                   "id" => member_id,
                   "email" => "member.e2e@example.test",
                   "email_verified_at" => nil
                 }
               }
             }
           } =
             Req.post!("#{base_url}/api/v1/auth/registrations",
               json: %{
                 "email" => "member.e2e@example.test",
                 "password" => @password,
                 "legal_document_version_ids" => [terms.version_id]
               },
               retry: false
             )

    verification_token = receive_verification_token()

    assert %Req.Response{status: 204, body: ""} =
             Req.post!("#{base_url}/api/v1/auth/email-verifications",
               json: %{"token" => verification_token},
               retry: false
             )

    assert %Req.Response{
             status: 200,
             body: %{
               "data" => %{
                 "user" => %{
                   "id" => ^member_id,
                   "email_verified_at" => verified_at
                 }
               }
             }
           } =
             Req.get!("#{base_url}/api/v1/me",
               headers: [{"authorization", "Bearer #{token}"}],
               retry: false
             )

    assert {:ok, _verified_at, 0} = DateTime.from_iso8601(verified_at)

    checkout_url = "#{base_url}/api/v1/polos/#{fixture.polo_route.slug}/orders"

    request = [
      headers: [
        {"authorization", "Bearer #{token}"},
        {"idempotency-key", "e2e-checkout-tcp-001"}
      ],
      json: %{
        "product_offering_version_id" => fixture.offering_version.id,
        "offering_price_id" => fixture.price.id
      },
      retry: false
    ]

    assert %Req.Response{
             status: 201,
             body: %{
               "data" => %{
                 "id" => order_id,
                 "order_number" => order_number,
                 "status" => "awaiting_payment"
               }
             }
           } = Req.post!(checkout_url, request)

    assert %Req.Response{
             status: 201,
             body: %{"data" => %{"id" => ^order_id, "status" => "awaiting_payment"}}
           } = Req.post!(checkout_url, request)

    assert %Req.Response{
             status: 200,
             body: %{
               "data" => [%{"id" => ^order_id, "status" => "awaiting_payment"}],
               "meta" => %{"count" => 1}
             }
           } =
             Req.get!("#{base_url}/api/v1/polos/#{fixture.polo_route.slug}/me/orders",
               headers: [{"authorization", "Bearer #{token}"}],
               retry: false
             )

    configure_mercado_pago!(fixture)

    provider_reference = "ORD-E2E-HTTP-001"
    payment_reference = "PAY-E2E-HTTP-001"
    occurred_at = DateTime.utc_now(:microsecond)

    expect_pix_lifecycle!(
      fixture,
      order_id,
      provider_reference,
      payment_reference,
      occurred_at
    )

    assert %Req.Response{
             status: 201,
             body: %{
               "data" => %{
                 "order_id" => ^order_id,
                 "provider" => "mercado_pago",
                 "provider_reference" => ^provider_reference,
                 "status" => "requires_action",
                 "next_action" => %{"type" => "pix"}
               }
             }
           } =
             Req.post!("#{checkout_url}/#{order_id}/payment-intents",
               headers: [
                 {"authorization", "Bearer #{token}"},
                 {"idempotency-key", "e2e-payment-tcp-001"}
               ],
               json: %{"payment_method" => "pix"},
               retry: false
             )

    webhook_request_id = Ecto.UUID.generate(version: 7)
    signature = webhook_signature(provider_reference, webhook_request_id)
    query = URI.encode_query(%{"data.id" => provider_reference, "type" => "order"})

    assert %Req.Response{status: 200, body: ""} =
             Req.post!(
               "#{base_url}/api/v1/webhooks/mercado-pago/#{fixture.merchant_account.id}?#{query}",
               headers: [
                 {"x-request-id", webhook_request_id},
                 {"x-signature", signature}
               ],
               json: %{
                 "action" => "order.processed",
                 "id" => "notification-e2e-http-001",
                 "type" => "order",
                 "data" => %{"id" => provider_reference}
               },
               retry: false
             )

    assert %Req.Response{
             status: 200,
             body: %{"data" => [%{"id" => ^order_id, "status" => "paid"}]}
           } =
             Req.get!("#{base_url}/api/v1/polos/#{fixture.polo_route.slug}/me/orders",
               headers: [{"authorization", "Bearer #{token}"}],
               retry: false
             )

    assert %Req.Response{
             status: 200,
             body: %{
               "data" => [
                 %{
                   "id" => contract_id,
                   "status" => "active",
                   "current_cycle" => %{"status" => "active"}
                 }
               ]
             }
           } =
             Req.get!("#{base_url}/api/v1/me/subscriptions",
               headers: [{"authorization", "Bearer #{token}"}],
               retry: false
             )

    admin_scope =
      ReviewsFixtures.grant_moderator!(
        %{ids: %{polo: fixture.polo.id}, scope: fixture.service_scope},
        role_key: "admin"
      )

    admin = Repo.get!(User, admin_scope.actor_user_id)
    assert {:ok, _credential} = Accounts.set_password(admin, @password)

    assert %Req.Response{
             status: 201,
             body: %{"data" => %{"access_token" => admin_token}}
           } =
             Req.post!("#{base_url}/api/v1/auth/sessions",
               json: %{"email" => admin.email, "password" => @password},
               retry: false
             )

    partner_organization = Factory.insert(:organization)

    Factory.insert(:place_operator,
      place: Repo.get!(Place, fixture.polo_place.place_id),
      organization: partner_organization
    )

    Factory.insert(:place_category, key: "e2e-cafe", name: "Café E2E")

    assert %Req.Response{
             status: 201,
             body: %{"data" => %{"access_token" => partner_token}}
           } =
             Req.post!("#{base_url}/api/v1/auth/registrations",
               json: %{
                 "email" => "partner.e2e@example.test",
                 "password" => @password,
                 "legal_document_version_ids" => [terms.version_id]
               },
               retry: false
             )

    partner_verification_token = receive_verification_token()

    assert %Req.Response{status: 204, body: ""} =
             Req.post!("#{base_url}/api/v1/auth/email-verifications",
               json: %{"token" => partner_verification_token},
               retry: false
             )

    partner_access_url =
      "#{base_url}/api/v1/polos/#{fixture.polo_route.slug}/backoffice/places/" <>
        "#{fixture.polo_place.place_id}/partner-accesses"

    assert %Req.Response{
             status: 201,
             body: %{
               "data" => %{
                 "id" => partner_access_id,
                 "place_id" => place_id,
                 "status" => "active"
               }
             }
           } =
             Req.post!(partner_access_url,
               headers: [
                 {"authorization", "Bearer #{admin_token}"},
                 {"idempotency-key", "e2e-partner-access-grant"}
               ],
               json: %{"email" => "partner.e2e@example.test"},
               retry: false
             )

    assert place_id == fixture.polo_place.place_id

    partner_places_url =
      "#{base_url}/api/v1/polos/#{fixture.polo_route.slug}/partner/places"

    assert %Req.Response{
             status: 200,
             body: %{"data" => [%{"place" => %{"id" => ^place_id}}], "meta" => %{"count" => 1}}
           } =
             Req.get!(partner_places_url,
               headers: [{"authorization", "Bearer #{partner_token}"}],
               retry: false
             )

    assert %Req.Response{
             status: 200,
             body: %{"data" => %{"place_id" => ^place_id, "profile" => %{"revision" => 1}}}
           } =
             Req.put!("#{partner_places_url}/#{place_id}/profile",
               headers: [
                 {"authorization", "Bearer #{partner_token}"},
                 {"idempotency-key", "e2e-partner-profile"}
               ],
               json: %{
                 "contact" => %{
                   "email" => "partner-public.e2e@example.test",
                   "phone" => "(88) 99999-0101"
                 },
                 "category_keys" => ["e2e-cafe"],
                 "weekly_hours" => [
                   %{"weekday" => 1, "opens_at" => "08:00", "closes_at" => "18:00"}
                 ],
                 "special_hours" => []
               },
               retry: false
             )

    assert %Req.Response{
             status: 200,
             body: %{
               "data" => %{
                 "places" => [
                   %{
                     "place_id" => ^place_id,
                     "profile" => %{
                       "contact" => %{"email" => "partner-public.e2e@example.test"}
                     }
                   }
                 ]
               }
             }
           } =
             Req.get!(
               "#{base_url}/api/v1/polos/#{fixture.polo_route.slug}/places",
               retry: false
             )

    assert %Req.Response{status: 200, body: %{"data" => %{"status" => "revoked"}}} =
             Req.post!(
               "#{base_url}/api/v1/polos/#{fixture.polo_route.slug}/backoffice/" <>
                 "partner-accesses/#{partner_access_id}/revocations",
               headers: [
                 {"authorization", "Bearer #{admin_token}"},
                 {"idempotency-key", "e2e-partner-access-revocation"}
               ],
               json: %{"reason" => "Encerramento do cenário E2E"},
               retry: false
             )

    assert %Req.Response{status: 403, body: %{"errors" => %{"detail" => "Forbidden"}}} =
             Req.get!(partner_places_url,
               headers: [{"authorization", "Bearer #{partner_token}"}],
               retry: false
             )

    query = URI.encode_query(%{"order_number" => order_number})

    assert %Req.Response{
             status: 200,
             body: %{
               "data" => [
                 %{
                   "id" => ^contract_id,
                   "status" => "active",
                   "order" => %{"id" => ^order_id, "order_number" => ^order_number},
                   "balance" => %{"issued_units" => 2, "available_units" => 2}
                 }
               ],
               "meta" => %{"count" => 1}
             }
           } =
             Req.get!(
               "#{base_url}/api/v1/polos/#{fixture.polo_route.slug}/backoffice/subscriptions?#{query}",
               headers: [{"authorization", "Bearer #{admin_token}"}],
               retry: false
             )

    assert %Req.Response{
             status: 200,
             body: %{"data" => %{"vouchers" => [voucher | _rest]}}
           } =
             Req.get!("#{base_url}/api/v1/polos/#{fixture.polo_route.slug}/me/vouchers",
               headers: [{"authorization", "Bearer #{token}"}],
               retry: false
             )

    validation_material = :crypto.strong_rand_bytes(32)
    validation_secret = Base.url_encode64(validation_material, padding: false)

    validation_secret_sha256 =
      validation_material
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    validation_expires_at =
      DateTime.utc_now(:second)
      |> DateTime.add(90, :day)
      |> DateTime.to_iso8601()

    assert %Req.Response{
             status: 201,
             body: %{"data" => %{"id" => validation_point_id}}
           } =
             Req.post!(
               "#{base_url}/api/v1/polos/#{fixture.polo_route.slug}/backoffice/places/" <>
                 "#{fixture.polo_place.place_id}/validation-points",
               headers: [
                 {"authorization", "Bearer #{admin_token}"},
                 {"idempotency-key", "e2e-validation-point-001"}
               ],
               json: %{
                 "name" => "Caixa E2E",
                 "credential" => %{
                   "secret_sha256" => validation_secret_sha256,
                   "expires_at" => validation_expires_at
                 }
               },
               retry: false
             )

    installation_token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    assert %Req.Response{status: 201, body: %{"data" => %{"id" => device_id}}} =
             Req.post!(
               "#{base_url}/api/v1/polos/#{fixture.polo_route.slug}/me/redemption-devices",
               headers: [{"authorization", "Bearer #{token}"}],
               json: %{
                 "access_contract_id" => contract_id,
                 "installation_token" => installation_token,
                 "platform" => "android"
               },
               retry: false
             )

    assert is_binary(device_id)

    assert %Req.Response{
             status: 201,
             body: %{"data" => %{"grant" => grant, "expires_at" => grant_expires_at}}
           } =
             Req.post!(
               "#{base_url}/api/v1/polos/#{fixture.polo_route.slug}/me/redemption-grants",
               headers: [{"authorization", "Bearer #{token}"}],
               json: %{
                 "entitlement_allocation_id" => voucher["allocation_id"],
                 "installation_token" => installation_token
               },
               retry: false
             )

    assert {:ok, _grant_expires_at, 0} = DateTime.from_iso8601(grant_expires_at)

    redemption_request = [
      headers: [
        {"authorization", "Validation #{validation_secret}"},
        {"idempotency-key", "e2e-redemption-001"}
      ],
      json: %{"grant" => grant},
      retry: false
    ]

    redemption_url = "#{base_url}/api/v1/polos/#{fixture.polo_route.slug}/redemptions"

    assert %Req.Response{
             status: 201,
             body: %{
               "data" => %{
                 "id" => redemption_id,
                 "entitlement_allocation_id" => allocation_id,
                 "validation_point_id" => ^validation_point_id,
                 "units" => 1
               }
             }
           } = first_redemption = Req.post!(redemption_url, redemption_request)

    assert allocation_id == voucher["allocation_id"]

    assert %Req.Response{status: 201, body: replayed_redemption} =
             Req.post!(redemption_url, redemption_request)

    assert replayed_redemption == first_redemption.body

    reviews_url =
      "#{base_url}/api/v1/polos/#{fixture.polo_route.slug}/places/" <>
        "#{fixture.polo_place.place_id}/reviews"

    assert %Req.Response{
             status: 201,
             body: %{
               "data" => %{
                 "id" => review_id,
                 "source_redemption_id" => ^redemption_id,
                 "status" => "pending",
                 "rating" => 5
               }
             }
           } =
             Req.post!(reviews_url,
               headers: [
                 {"authorization", "Bearer #{token}"},
                 {"idempotency-key", "e2e-review-001"}
               ],
               json: %{
                 "source_redemption_id" => redemption_id,
                 "rating" => 5,
                 "title" => "Jornada E2E concluída",
                 "body" => "O voucher foi validado pelo estabelecimento."
               },
               retry: false
             )

    assert %Req.Response{
             status: 200,
             body: %{"data" => [%{"id" => ^review_id, "status" => "pending"}]}
           } =
             Req.get!(
               "#{base_url}/api/v1/polos/#{fixture.polo_route.slug}/backoffice/reviews",
               headers: [{"authorization", "Bearer #{admin_token}"}],
               retry: false
             )

    assert %Req.Response{
             status: 201,
             body: %{
               "data" => %{
                 "review_id" => ^review_id,
                 "action" => "publish",
                 "status" => "published"
               }
             }
           } =
             Req.post!(
               "#{base_url}/api/v1/polos/#{fixture.polo_route.slug}/backoffice/reviews/" <>
                 "#{review_id}/moderation-actions",
               headers: [
                 {"authorization", "Bearer #{admin_token}"},
                 {"idempotency-key", "e2e-review-moderation-001"}
               ],
               json: %{
                 "action" => "publish",
                 "reason" => "Conteúdo verificado pela jornada E2E."
               },
               retry: false
             )

    assert %Req.Response{
             status: 200,
             body: %{"data" => [%{"id" => ^review_id, "rating" => 5}]}
           } = Req.get!(reviews_url, retry: false)

    reporter = Factory.insert(:user, email: "reporter.e2e@example.test")
    assert {:ok, _credential} = Accounts.set_password(reporter, @password)

    assert %Req.Response{
             status: 201,
             body: %{"data" => %{"access_token" => reporter_token}}
           } =
             Req.post!("#{base_url}/api/v1/auth/sessions",
               json: %{"email" => reporter.email, "password" => @password},
               retry: false
             )

    assert %Req.Response{
             status: 201,
             body: %{
               "data" => %{
                 "id" => review_report_id,
                 "review_id" => ^review_id,
                 "reason_code" => "offensive_content",
                 "status" => "open"
               }
             }
           } =
             Req.post!("#{reviews_url}/#{review_id}/reports",
               headers: [
                 {"authorization", "Bearer #{reporter_token}"},
                 {"idempotency-key", "e2e-review-report-001"}
               ],
               json: %{
                 "reason_code" => "offensive_content",
                 "details" => "Conteúdo denunciado pela jornada E2E."
               },
               retry: false
             )

    assert %Req.Response{
             status: 200,
             body: %{
               "data" => [
                 %{
                   "id" => ^review_report_id,
                   "review_id" => ^review_id,
                   "status" => "open",
                   "review" => %{"status" => "published"}
                 }
               ]
             }
           } =
             Req.get!(
               "#{base_url}/api/v1/polos/#{fixture.polo_route.slug}/backoffice/review-reports",
               headers: [{"authorization", "Bearer #{admin_token}"}],
               retry: false
             )

    assert %Req.Response{
             status: 201,
             body: %{
               "data" => %{
                 "review_report_id" => ^review_report_id,
                 "review_id" => ^review_id,
                 "action" => "hide",
                 "report_status" => "accepted",
                 "review_status" => "hidden"
               }
             }
           } =
             Req.post!(
               "#{base_url}/api/v1/polos/#{fixture.polo_route.slug}/backoffice/" <>
                 "review-reports/#{review_report_id}/moderation-actions",
               headers: [
                 {"authorization", "Bearer #{admin_token}"},
                 {"idempotency-key", "e2e-review-report-resolution-001"}
               ],
               json: %{
                 "action" => "hide",
                 "reason" => "Denúncia confirmada pela jornada E2E."
               },
               retry: false
             )

    assert %Req.Response{
             status: 200,
             body: %{
               "data" => [],
               "page" => %{"limit" => 20, "has_more" => false, "next_cursor" => nil}
             }
           } = Req.get!(reviews_url, retry: false)

    assert %Req.Response{
             status: 200,
             body: %{
               "data" => [
                 %{
                   "id" => payment_id,
                   "status" => "captured",
                   "order" => %{"id" => ^order_id}
                 }
               ]
             }
           } =
             Req.get!(
               "#{base_url}/api/v1/polos/#{fixture.polo_route.slug}/backoffice/payments?" <>
                 URI.encode_query(%{"order_number" => order_number}),
               headers: [{"authorization", "Bearer #{admin_token}"}],
               retry: false
             )

    provider_refund_reference = "REF-E2E-HTTP-001"

    Req.Test.expect(MercadoPago, fn request ->
      assert request.method == "POST"
      assert request.request_path == "/v1/orders/#{provider_reference}/refund"

      request
      |> Plug.Conn.put_status(:created)
      |> Req.Test.json(
        refunded_order_response(
          fixture,
          order_id,
          provider_reference,
          payment_reference,
          provider_refund_reference
        )
      )
    end)

    assert %Req.Response{
             status: 201,
             body: %{
               "data" => %{
                 "payment_id" => ^payment_id,
                 "provider_reference" => ^provider_refund_reference,
                 "status" => "succeeded"
               }
             }
           } =
             Req.post!(
               "#{base_url}/api/v1/polos/#{fixture.polo_route.slug}/backoffice/payments/" <>
                 "#{payment_id}/refunds",
               headers: [
                 {"authorization", "Bearer #{admin_token}"},
                 {"idempotency-key", "e2e-refund-001"}
               ],
               json: %{"reason" => "Encerramento integral da jornada E2E"},
               retry: false
             )

    assert %Req.Response{
             status: 200,
             body: %{"data" => %{"vouchers" => []}, "meta" => %{"count" => 0}}
           } =
             Req.get!("#{base_url}/api/v1/polos/#{fixture.polo_route.slug}/me/vouchers",
               headers: [{"authorization", "Bearer #{token}"}],
               retry: false
             )

    assert %Req.Response{
             status: 200,
             body: %{
               "data" => [
                 %{
                   "id" => ^redemption_id,
                   "review" => %{"id" => ^review_id, "status" => "hidden"}
                 }
               ]
             }
           } =
             Req.get!(
               "#{base_url}/api/v1/polos/#{fixture.polo_route.slug}/me/redemptions",
               headers: [{"authorization", "Bearer #{token}"}],
               retry: false
             )
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

  defp expect_pix_lifecycle!(
         fixture,
         order_id,
         provider_reference,
         payment_reference,
         occurred_at
       ) do
    Req.Test.expect(MercadoPago, 2, fn request ->
      case {request.method, request.request_path} do
        {"POST", "/v1/orders"} ->
          Req.Test.json(
            request,
            pix_order_response(
              fixture,
              order_id,
              provider_reference,
              payment_reference,
              "action_required",
              occurred_at
            )
          )

        {"GET", "/v1/orders/" <> ^provider_reference} ->
          Req.Test.json(
            request,
            pix_order_response(
              fixture,
              order_id,
              provider_reference,
              payment_reference,
              "processed",
              occurred_at
            )
          )
      end
    end)
  end

  defp pix_order_response(
         fixture,
         order_id,
         provider_reference,
         payment_reference,
         status,
         occurred_at
       ) do
    status_detail = if status == "processed", do: "accredited", else: "waiting_transfer"

    %{
      id: provider_reference,
      type: "online",
      status: status,
      status_detail: status_detail,
      total_amount: Decimal.to_string(fixture.price.amount),
      currency: fixture.price.currency,
      external_reference: "#{fixture.polo.id}_#{order_id}",
      last_updated_date: DateTime.to_iso8601(occurred_at),
      transactions: %{
        payments: [
          %{
            id: payment_reference,
            status: status,
            status_detail: status_detail,
            amount: Decimal.to_string(fixture.price.amount),
            payment_method: %{
              id: "pix",
              type: "bank_transfer",
              ticket_url: "https://www.mercadopago.com.br/sandbox/payments/e2e/ticket",
              qr_code: "000201010212e2e-pix-code"
            }
          }
        ]
      }
    }
  end

  defp webhook_signature(data_id, request_id) do
    timestamp = System.system_time(:millisecond) |> Integer.to_string()
    manifest = "id:#{data_id};request-id:#{request_id};ts:#{timestamp};"

    digest =
      :crypto.mac(:hmac, :sha256, @webhook_secret, manifest)
      |> Base.encode16(case: :lower)

    "ts=#{timestamp},v1=#{digest}"
  end

  defp receive_verification_token do
    assert_email_sent(fn email ->
      assert email.subject == "Confirme seu e-mail do Clubeira"
      assert [_, token] = Regex.run(~r/[?&]token=([A-Za-z0-9_-]{43})/, email.text_body)
      send(self(), {:email_verification_token, token})
      true
    end)

    assert_receive {:email_verification_token, token}
    token
  end

  defp refunded_order_response(
         fixture,
         order_id,
         provider_reference,
         payment_reference,
         provider_refund_reference
       ) do
    amount = Decimal.to_string(fixture.price.amount)

    %{
      id: provider_reference,
      status: "refunded",
      status_detail: "refunded",
      external_reference: "#{fixture.polo.id}_#{order_id}",
      total_amount: amount,
      currency: fixture.price.currency,
      last_updated_date: DateTime.to_iso8601(DateTime.utc_now(:microsecond)),
      transactions: %{
        payments: [
          %{
            id: payment_reference,
            status: "refunded",
            status_detail: "refunded",
            amount: amount
          }
        ],
        refunds: [
          %{
            id: provider_refund_reference,
            transaction_id: payment_reference,
            amount: amount,
            status: "processed"
          }
        ]
      }
    }
  end
end
