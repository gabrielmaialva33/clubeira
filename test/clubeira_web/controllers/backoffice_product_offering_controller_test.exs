defmodule ClubeiraWeb.BackofficeProductOfferingControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  import Ecto.Query

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Audit.TenantEvent
  alias Clubeira.Billing
  alias Clubeira.BillingFixtures
  alias Clubeira.Events.DomainEvent
  alias Clubeira.Events.OutboxMessage
  alias Clubeira.Factory
  alias Clubeira.Idempotency.Key
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures
  alias Clubeira.Subscriptions

  @password "uma-senha-forte-para-publicacao-comercial"

  test "an admin publishes a complete initial offering that becomes a checkout option", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    token = authenticate!(admin_scope.actor_user_id)
    benefit_version_id = publish_benefit!(conn, fixture, token)
    request = product_offering_request(benefit_version_id)

    response =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("idempotency-key", "product-offering-publish-001")
      |> post(product_offerings_path(fixture), request)
      |> json_response(201)

    assert %{
             "data" => %{
               "access_product" => %{
                 "id" => access_product_id,
                 "version_id" => access_product_version_id,
                 "code" => "clube-sobral-premium",
                 "name" => "Clube Sobral Premium"
               },
               "product_offering" => %{
                 "id" => product_offering_id,
                 "version_id" => product_offering_version_id,
                 "version" => 1,
                 "status" => "published",
                 "activation_policy" => "payment_confirmation",
                 "renewal_policy" => "none",
                 "cycle" => %{
                   "policy" => "calendar",
                   "interval_unit" => "month",
                   "interval_count" => 1
                 }
               },
               "price" => %{
                 "id" => offering_price_id,
                 "key" => "default",
                 "currency" => "BRL",
                 "amount" => "39.90",
                 "billing_model" => "subscription"
               },
               "benefit_package" => %{
                 "id" => benefit_package_id,
                 "version_id" => benefit_package_version_id,
                 "version" => 1,
                 "item_count" => 1
               },
               "benefits" => [
                 %{
                   "benefit_offer_version_id" => ^benefit_version_id,
                   "benefit_package_item_id" => benefit_package_item_id,
                   "allowance_per_cycle" => 2,
                   "consumption_unit" => "per_place",
                   "polo_place_ids" => [polo_place_id]
                 }
               ]
             }
           } = response

    for id <- [
          access_product_id,
          access_product_version_id,
          product_offering_id,
          product_offering_version_id,
          offering_price_id,
          benefit_package_id,
          benefit_package_version_id,
          benefit_package_item_id
        ] do
      assert Ecto.UUID.cast(id) == {:ok, id}
    end

    assert polo_place_id == fixture.polo_place.id

    option =
      conn
      |> recycle()
      |> get("/api/v1/polos/#{fixture.polo_route.slug}/checkout-options")
      |> json_response(200)
      |> get_in(["data", "options"])
      |> Enum.find(&(&1["product_offering_version_id"] == product_offering_version_id))

    assert option == %{
             "product_offering_version_id" => product_offering_version_id,
             "offering_price_id" => offering_price_id,
             "name" => "Clube Sobral Premium",
             "description" => "Plano mensal com os benefícios premium publicados pelo polo.",
             "cycle" => %{
               "policy" => "calendar",
               "interval_unit" => "month",
               "interval_count" => 1
             },
             "renewal_policy" => "none",
             "price" => %{
               "key" => "default",
               "currency" => "BRL",
               "amount" => "39.90",
               "billing_model" => "subscription",
               "interval_unit" => "month",
               "interval_count" => 1,
               "installments" => 1
             }
           }
  end

  test "a published offering settles into the configured entitlement", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    token = authenticate!(admin_scope.actor_user_id)
    benefit_version_id = publish_benefit!(conn, fixture, token)

    published = publish_product_offering!(conn, fixture, token, benefit_version_id)

    assert {:ok, order} =
             Billing.place_order(fixture.member_scope, %{
               product_offering_version_id: published["product_offering"]["version_id"],
               offering_price_id: published["price"]["id"],
               idempotency_key: "checkout-published-product-offering"
             })

    assert {:ok, contract} =
             Billing.settle_payment(
               fixture.service_scope,
               BillingFixtures.settled_payment(fixture, order)
             )

    assert contract.product_offering_version_id ==
             published["product_offering"]["version_id"]

    assert {:ok, wallet} =
             Subscriptions.list_wallet(fixture.account_scope, fixture.polo_route.slug)

    assert [voucher] =
             Enum.filter(
               wallet.vouchers,
               &(&1.offer.version_id == benefit_version_id)
             )

    assert voucher.issued_units == 2
    assert voucher.available_units == 2
    assert voucher.allocation_kind == "per_place"
    assert Enum.map(voucher.places, & &1.polo_place_id) == [fixture.polo_place.id]
  end

  test "an exact retry replays one atomic observable commercial publication", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    token = authenticate!(admin_scope.actor_user_id)
    benefit_version_id = publish_benefit!(conn, fixture, token)
    key = "product-offering-observable-replay"
    request = product_offering_request(benefit_version_id)

    first = publish_product_offering_request!(conn, fixture, token, request, key)
    replayed = publish_product_offering_request!(conn, fixture, token, request, key)

    assert replayed == first

    changed_request =
      put_in(request, ["benefits", Access.at(0), "allowance_per_cycle"], 3)

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", key)
           |> post(product_offerings_path(fixture), changed_request)
           |> json_response(409) == %{
             "errors" => %{
               "code" => "idempotency_conflict",
               "detail" => "Conflict"
             }
           }

    offering_id = first["product_offering"]["id"]

    assert {:ok, :verified} =
             Repo.transact_in_polo(admin_scope, fn repo ->
               event =
                 repo.one!(
                   from(event in DomainEvent,
                     where:
                       event.aggregate_id == ^offering_id and
                         event.event_type == "product_offering.published"
                   )
                 )

               audit =
                 repo.one!(
                   from(audit in TenantEvent,
                     where:
                       audit.resource_id == ^offering_id and
                         audit.action == "product_offering.published"
                   )
                 )

               outbox = repo.get_by!(OutboxMessage, domain_event_id: event.id)

               idempotency =
                 repo.one!(
                   from(idempotency in Key,
                     where:
                       idempotency.scope == "subscriptions.publish_product_offering" and
                         idempotency.idempotency_key == ^key
                   )
                 )

               assert event.aggregate_version == 1
               assert event.aggregate_id == audit.resource_id
               assert event.aggregate_id == idempotency.resource_id
               assert idempotency.response_body == first
               assert idempotency.response_status == 201
               assert outbox.topic == "subscriptions.product_offerings.published"
               assert outbox.message_key == offering_id

               assert repo.aggregate(
                        from(event in DomainEvent, where: event.aggregate_id == ^offering_id),
                        :count
                      ) == 1

               assert repo.aggregate(
                        from(audit in TenantEvent, where: audit.resource_id == ^offering_id),
                        :count
                      ) == 1

               {:ok, :verified}
             end)
  end

  test "a code conflict in a later commercial identity rolls back the graph and replays stably",
       %{
         conn: conn
       } do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    token = authenticate!(admin_scope.actor_user_id)
    benefit_version_id = publish_benefit!(conn, fixture, token)
    request = product_offering_request(benefit_version_id)
    key = "product-offering-package-code-conflict"

    assert {:ok, _package} =
             Repo.transact_in_polo(admin_scope, fn _repo ->
               {:ok,
                Factory.insert(:benefit_package,
                  polo: fixture.polo,
                  code: "clube-sobral-premium"
                )}
             end)

    for _retry <- 1..2 do
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> put_req_header("idempotency-key", key)
             |> post(product_offerings_path(fixture), request)
             |> json_response(409) == %{
               "errors" => %{
                 "code" => "product_offering_code_conflict",
                 "detail" => "Conflict"
               }
             }
    end

    assert {:ok, %{rows: [[0, 0, 1, 1, 1]]}} =
             Repo.transact_in_polo(admin_scope, fn repo ->
               {:ok,
                repo.query!(
                  """
                  SELECT
                    (SELECT count(*) FROM access_products WHERE code = 'clube-sobral-premium'),
                    (SELECT count(*) FROM product_offerings WHERE code = 'clube-sobral-premium'),
                    (SELECT count(*) FROM benefit_packages WHERE code = 'clube-sobral-premium'),
                    (
                      SELECT count(*)
                      FROM tenant_idempotency_keys
                      WHERE scope = 'subscriptions.publish_product_offering'
                        AND idempotency_key = $1
                        AND status = 'failed'
                    ),
                    (
                      SELECT count(*)
                      FROM tenant_audit_events
                      WHERE action = 'product_offering.publication_rejected'
                    )
                  """,
                  [key]
                )}
             end)
  end

  test "only a routed polo admin can publish and cross-polo benefits stay hidden", %{conn: conn} do
    fixture = BillingFixtures.create!()
    other_polo = BillingFixtures.create!()

    moderator_scope =
      ReviewsFixtures.grant_moderator!(%{
        ids: %{polo: fixture.polo.id},
        scope: fixture.service_scope
      })

    admin_scope = grant_admin!(fixture)
    moderator_token = authenticate!(moderator_scope.actor_user_id)
    admin_token = authenticate!(admin_scope.actor_user_id)
    benefit_version_id = publish_benefit!(conn, fixture, admin_token)
    valid_request = product_offering_request(benefit_version_id)

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{moderator_token}")
           |> put_req_header("idempotency-key", "product-offering-moderator-forbidden")
           |> post(product_offerings_path(fixture), valid_request)
           |> json_response(403) == %{"errors" => %{"detail" => "Forbidden"}}

    cross_polo_version_id = hd(other_polo.package_items).benefit_offer_version_id

    cross_polo_request =
      put_in(
        valid_request,
        ["benefits", Access.at(0), "benefit_offer_version_id"],
        cross_polo_version_id
      )

    for _retry <- 1..2 do
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> put_req_header("idempotency-key", "product-offering-cross-polo-benefit")
             |> post(product_offerings_path(fixture), cross_polo_request)
             |> json_response(404) == %{
               "errors" => %{
                 "code" => "benefit_offer_version_not_found",
                 "detail" => "Not Found"
               }
             }
    end

    assert {:ok, %{rows: [[0, 1, 1]]}} =
             Repo.transact_in_polo(admin_scope, fn repo ->
               {:ok,
                repo.query!("""
                SELECT
                  (SELECT count(*) FROM access_products WHERE code = 'clube-sobral-premium'),
                  (
                    SELECT count(*)
                    FROM tenant_idempotency_keys
                    WHERE scope = 'subscriptions.publish_product_offering'
                      AND idempotency_key = 'product-offering-cross-polo-benefit'
                      AND status = 'failed'
                  ),
                  (
                    SELECT count(*)
                    FROM tenant_audit_events
                    WHERE action = 'product_offering.publication_rejected'
                  )
                """)}
             end)
  end

  test "an existing benefit that cannot cover the offering period returns a replayable conflict",
       %{
         conn: conn
       } do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    token = authenticate!(admin_scope.actor_user_id)

    benefit_version_id =
      publish_benefit!(conn, fixture, token,
        ends_at: DateTime.utc_now(:microsecond) |> DateTime.add(3_600) |> DateTime.to_iso8601()
      )

    request = product_offering_request(benefit_version_id)
    key = "product-offering-benefit-unavailable"

    for _retry <- 1..2 do
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> put_req_header("idempotency-key", key)
             |> post(product_offerings_path(fixture), request)
             |> json_response(409) == %{
               "errors" => %{
                 "code" => "benefit_configuration_unavailable",
                 "detail" => "Conflict"
               }
             }
    end

    assert {:ok, %{rows: [[0, 1, 1]]}} =
             Repo.transact_in_polo(admin_scope, fn repo ->
               {:ok,
                repo.query!(
                  """
                  SELECT
                    (SELECT count(*) FROM access_products WHERE code = 'clube-sobral-premium'),
                    (
                      SELECT count(*)
                      FROM tenant_idempotency_keys
                      WHERE scope = 'subscriptions.publish_product_offering'
                        AND idempotency_key = $1
                        AND status = 'failed'
                    ),
                    (
                      SELECT count(*)
                      FROM tenant_audit_events
                      WHERE action = 'product_offering.publication_rejected'
                    )
                  """,
                  [key]
                )}
             end)
  end

  test "invalid commercial contracts are rejected before reserving an idempotency key", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    token = authenticate!(admin_scope.actor_user_id)
    benefit_version_id = publish_benefit!(conn, fixture, token)
    request = product_offering_request(benefit_version_id)
    benefit = hd(request["benefits"])
    starts_at = get_in(request, ["offering", "effective_during", "starts_at"])

    invalid_requests = [
      put_in(request, ["offering", "code"], "Código Inválido"),
      put_in(request, ["offering", "description"], " "),
      put_in(request, ["offering", "cycle", "policy"], "single"),
      put_in(request, ["offering", "cycle", "interval_count"], 0),
      put_in(request, ["offering", "effective_during", "ends_at"], starts_at),
      put_in(request, ["price", "amount"], "39.901"),
      put_in(request, ["price", "currency"], "R1"),
      Map.put(request, "benefits", []),
      Map.put(request, "benefits", [benefit, benefit]),
      put_in(request, ["benefits", Access.at(0), "benefit_offer_version_id"], "not-a-uuid"),
      put_in(request, ["benefits", Access.at(0), "allowance_per_cycle"], 0),
      put_in(request, ["benefits", Access.at(0), "consumption_unit"], "global")
    ]

    invalid_requests
    |> Enum.with_index(1)
    |> Enum.each(fn {invalid_request, index} ->
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> put_req_header("idempotency-key", "product-offering-invalid-#{index}")
             |> post(product_offerings_path(fixture), invalid_request)
             |> json_response(422) == %{
               "errors" => %{"detail" => "Unprocessable Content"}
             }
    end)

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{token}")
           |> post(product_offerings_path(fixture), request)
           |> json_response(400) == %{
             "errors" => %{
               "code" => "invalid_idempotency_key",
               "detail" => "Bad Request"
             }
           }

    assert {:ok, %{rows: [[0, 0]]}} =
             Repo.transact_in_polo(admin_scope, fn repo ->
               {:ok,
                repo.query!("""
                SELECT
                  (SELECT count(*) FROM access_products WHERE code = 'clube-sobral-premium'),
                  (
                    SELECT count(*)
                    FROM tenant_idempotency_keys
                    WHERE idempotency_key LIKE 'product-offering-invalid-%'
                  )
                """)}
             end)
  end

  test "equivalent decimal and benefit ordering replay one multi-benefit graph", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    token = authenticate!(admin_scope.actor_user_id)
    published_benefit_id = publish_benefit!(conn, fixture, token)
    existing_benefit_id = hd(fixture.package_items).benefit_offer_version_id
    key = "product-offering-canonical-replay"

    request = product_offering_request(published_benefit_id)

    existing_benefit = %{
      "benefit_offer_version_id" => existing_benefit_id,
      "allowance_per_cycle" => 1,
      "consumption_unit" => "shared_scope"
    }

    first_request =
      Map.update!(request, "benefits", &[existing_benefit | &1])

    equivalent_request =
      first_request
      |> update_in(["benefits"], &Enum.reverse/1)
      |> put_in(["price", "amount"], "39.90")
      |> put_in(["price", "currency"], "BRL")

    first = publish_product_offering_request!(conn, fixture, token, first_request, key)

    replayed =
      publish_product_offering_request!(conn, fixture, token, equivalent_request, key)

    assert replayed == first
    assert first["benefit_package"]["item_count"] == 2

    assert Enum.map(first["benefits"], & &1["benefit_offer_version_id"]) ==
             Enum.sort([published_benefit_id, existing_benefit_id])
  end

  defp grant_admin!(fixture) do
    ReviewsFixtures.grant_moderator!(
      %{ids: %{polo: fixture.polo.id}, scope: fixture.service_scope},
      role_key: "admin"
    )
  end

  defp publish_benefit!(conn, fixture, token, options \\ []) do
    starts_at = DateTime.utc_now(:microsecond) |> DateTime.add(-60) |> DateTime.to_iso8601()
    ends_at = Keyword.get(options, :ends_at)

    request = %{
      "offer" => %{
        "code" => "cafe-premium",
        "name" => "Café premium",
        "benefit_kind" => "discount_percentage"
      },
      "version" => %{
        "title" => "20% no café premium",
        "description" => "Desconto publicado para a nova configuração comercial.",
        "terms" => "Dois usos por ciclo.",
        "redemption_instructions" => "Apresente o voucher antes de pedir a conta.",
        "percentage_value" => "20.0000",
        "effective_during" => %{"starts_at" => starts_at, "ends_at" => ends_at}
      }
    }

    conn
    |> recycle()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("idempotency-key", "product-offering-benefit-001")
    |> post(
      "/api/v1/polos/#{fixture.polo_route.slug}/backoffice/places/#{fixture.polo_place.place_id}/benefit-offers",
      request
    )
    |> json_response(201)
    |> get_in(["data", "version", "id"])
  end

  defp product_offering_request(benefit_version_id) do
    starts_at = DateTime.utc_now(:microsecond) |> DateTime.add(-30) |> DateTime.to_iso8601()

    %{
      "offering" => %{
        "code" => "clube-sobral-premium",
        "name" => "Clube Sobral Premium",
        "description" => "Plano mensal com os benefícios premium publicados pelo polo.",
        "cycle" => %{
          "policy" => "calendar",
          "interval_unit" => "month",
          "interval_count" => 1
        },
        "effective_during" => %{"starts_at" => starts_at, "ends_at" => nil}
      },
      "price" => %{"currency" => " brl ", "amount" => "39.9"},
      "benefits" => [
        %{
          "benefit_offer_version_id" => benefit_version_id,
          "allowance_per_cycle" => 2,
          "consumption_unit" => "per_place"
        }
      ]
    }
  end

  defp publish_product_offering!(
         conn,
         fixture,
         token,
         benefit_version_id,
         idempotency_key \\ "product-offering-publish-entitlement"
       ) do
    request = product_offering_request(benefit_version_id)

    publish_product_offering_request!(conn, fixture, token, request, idempotency_key)
  end

  defp publish_product_offering_request!(conn, fixture, token, request, idempotency_key) do
    conn
    |> recycle()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("idempotency-key", idempotency_key)
    |> post(product_offerings_path(fixture), request)
    |> json_response(201)
    |> Map.fetch!("data")
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session.token
  end

  defp product_offerings_path(fixture) do
    "/api/v1/polos/#{fixture.polo_route.slug}/backoffice/product-offerings"
  end
end
