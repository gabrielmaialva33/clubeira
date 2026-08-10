defmodule ClubeiraWeb.Backoffice.SubscriptionControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Billing
  alias Clubeira.BillingFixtures
  alias Clubeira.Redemptions
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  @password "uma-senha-forte-para-assinaturas-backoffice"

  test "an authenticated polo admin lists the active subscription created by a captured payment",
       %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    admin_token = authenticate!(admin_scope.actor_user_id)

    {order, contract} = captured_subscription!(fixture)

    assert %{
             "data" => [
               %{
                 "id" => contract_id,
                 "status" => "active",
                 "purchaser_user_id" => purchaser_user_id,
                 "starts_at" => starts_at,
                 "activated_at" => activated_at,
                 "ends_at" => nil,
                 "cancelled_at" => nil,
                 "recorded_at" => recorded_at,
                 "order" => %{
                   "id" => order_id,
                   "order_number" => order_number,
                   "status" => "paid",
                   "placed_at" => placed_at
                 },
                 "offering" => %{
                   "version_id" => offering_version_id,
                   "version" => 1,
                   "name" => "Assinatura mensal",
                   "renewal_policy" => "none",
                   "cycle" => %{
                     "policy" => "calendar",
                     "interval_unit" => "month",
                     "interval_count" => 1
                   }
                 },
                 "current_cycle" => %{
                   "id" => cycle_id,
                   "sequence" => 1,
                   "status" => "active",
                   "starts_at" => cycle_starts_at,
                   "ends_at" => cycle_ends_at
                 },
                 "balance" => %{
                   "issued_units" => 2,
                   "available_units" => 2,
                   "consumed_units" => 0
                 }
               } = subscription
             ],
             "meta" => %{
               "count" => 1,
               "page" => %{"limit" => 20, "has_more" => false, "next_cursor" => nil}
             }
           } =
             conn
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get("/api/v1/polos/#{fixture.polo_route.slug}/backoffice/subscriptions")
             |> json_response(200)

    assert contract_id == contract.id
    assert purchaser_user_id == fixture.user.id
    assert order_id == order.id
    assert order_number == order.order_number
    assert offering_version_id == fixture.offering_version.id
    assert {:ok, ^cycle_id} = Ecto.UUID.cast(cycle_id)

    for timestamp <- [
          starts_at,
          activated_at,
          recorded_at,
          placed_at,
          cycle_starts_at,
          cycle_ends_at
        ] do
      assert {:ok, _datetime, 0} = DateTime.from_iso8601(timestamp)
    end

    refute Map.has_key?(subscription, "billing_agreement_id")
    refute Map.has_key?(subscription, "purchaser_email")
    refute Map.has_key?(subscription, "purchaser_document")
    refute Map.has_key?(subscription, "idempotency_key")
    refute Map.has_key?(subscription, "provider_reference")
  end

  test "the subscription feed paginates contracts with an opaque stable cursor", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    admin_token = authenticate!(admin_scope.actor_user_id)
    {_older_order, older_contract} = captured_subscription!(fixture)

    {_newer_order, newer_contract} =
      captured_subscription!(fixture, %{
        external_event_id: "evt-#{Ecto.UUID.generate()}",
        provider_reference: "pay-#{Ecto.UUID.generate()}"
      })

    path = "/api/v1/polos/#{fixture.polo_route.slug}/backoffice/subscriptions"

    assert %{
             "data" => [%{"id" => newer_contract_id, "status" => "active"}],
             "meta" => %{
               "count" => 1,
               "page" => %{"limit" => 1, "has_more" => true, "next_cursor" => cursor}
             }
           } =
             conn
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(path <> "?limit=1&status=active")
             |> json_response(200)

    assert newer_contract_id == newer_contract.id
    assert is_binary(cursor)
    refute cursor =~ newer_contract.id

    assert %{
             "data" => [%{"id" => older_contract_id, "status" => "active"}],
             "meta" => %{
               "count" => 1,
               "page" => %{"limit" => 1, "has_more" => false, "next_cursor" => nil}
             }
           } =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(path <> "?limit=1&status=active&after=#{cursor}")
             |> json_response(200)

    assert older_contract_id == older_contract.id
  end

  test "the subscription feed finds a contract by its exact order number", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    admin_token = authenticate!(admin_scope.actor_user_id)
    {expected_order, expected_contract} = captured_subscription!(fixture)

    {_other_order, _other_contract} =
      captured_subscription!(fixture, %{
        external_event_id: "evt-#{Ecto.UUID.generate()}",
        provider_reference: "pay-#{Ecto.UUID.generate()}"
      })

    query = URI.encode_query(%{"order_number" => expected_order.order_number})

    assert %{
             "data" => [
               %{
                 "id" => contract_id,
                 "order" => %{"id" => order_id, "order_number" => order_number}
               }
             ],
             "meta" => %{"count" => 1}
           } =
             conn
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get("/api/v1/polos/#{fixture.polo_route.slug}/backoffice/subscriptions?#{query}")
             |> json_response(200)

    assert contract_id == expected_contract.id
    assert order_id == expected_order.id
    assert order_number == expected_order.order_number
  end

  test "the subscription feed filters by purchaser and immutable offering version identities", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    admin_token = authenticate!(admin_scope.actor_user_id)
    {_order, contract} = captured_subscription!(fixture)
    path = "/api/v1/polos/#{fixture.polo_route.slug}/backoffice/subscriptions"

    matching_query =
      URI.encode_query(%{
        "purchaser_user_id" => fixture.user.id,
        "product_offering_version_id" => fixture.offering_version.id
      })

    assert %{"data" => [%{"id" => contract_id}], "meta" => %{"count" => 1}} =
             conn
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(path <> "?#{matching_query}")
             |> json_response(200)

    assert contract_id == contract.id

    for filter <- [
          %{"purchaser_user_id" => Ecto.UUID.generate()},
          %{"product_offering_version_id" => Ecto.UUID.generate()}
        ] do
      assert %{"data" => [], "meta" => %{"count" => 0}} =
               conn
               |> recycle()
               |> put_req_header("authorization", "Bearer #{admin_token}")
               |> get(path <> "?#{URI.encode_query(filter)}")
               |> json_response(200)
    end
  end

  test "the subscription feed requires a billing admin in the routed polo and never crosses tenants",
       %{conn: conn} do
    fixture = BillingFixtures.create!()
    other_polo = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)

    moderator_scope =
      ReviewsFixtures.grant_moderator!(%{
        ids: %{polo: fixture.polo.id},
        scope: fixture.service_scope
      })

    admin_token = authenticate!(admin_scope.actor_user_id)
    moderator_token = authenticate!(moderator_scope.actor_user_id)
    member_token = authenticate!(fixture.user.id)
    {_order, contract} = captured_subscription!(fixture)
    {_other_order, other_contract} = captured_subscription!(other_polo)
    path = "/api/v1/polos/#{fixture.polo_route.slug}/backoffice/subscriptions"

    for token <- [member_token, moderator_token] do
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> get(path)
             |> json_response(403) == %{"errors" => %{"detail" => "Forbidden"}}
    end

    assert %{"data" => [%{"id" => contract_id}]} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(path)
             |> json_response(200)

    assert contract_id == contract.id
    refute contract_id == other_contract.id

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> get("/api/v1/polos/polo-inexistente/backoffice/subscriptions")
           |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}
  end

  test "the subscription feed rejects malformed pagination and filters at the HTTP edge", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    admin_token = authenticate!(admin_scope.actor_user_id)
    path = "/api/v1/polos/#{fixture.polo_route.slug}/backoffice/subscriptions"

    for query <- ["limit=0", "limit=101", "after=not-a-cursor"] do
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(path <> "?#{query}")
             |> json_response(400) == %{"errors" => %{"detail" => "Bad Request"}}
    end

    for filter <- [
          %{"status" => "unknown"},
          %{"order_number" => "  "},
          %{"purchaser_user_id" => "not-a-uuid"},
          %{"product_offering_version_id" => "not-a-uuid"}
        ] do
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(path <> "?#{URI.encode_query(filter)}")
             |> json_response(422) == %{
               "errors" => %{"detail" => "Unprocessable Content"}
             }
    end
  end

  test "the subscription feed aggregates the remaining balance after a redemption", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)

    assert {:ok, _redemption} = Redemptions.confirm(fixture.scope, fixture.request)

    assert %{
             "data" => [
               %{
                 "id" => contract_id,
                 "balance" => %{
                   "issued_units" => 1,
                   "available_units" => 0,
                   "consumed_units" => 1
                 }
               }
             ],
             "meta" => %{"count" => 1}
           } =
             conn
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get("/api/v1/polos/#{fixture.polo_slug}/backoffice/subscriptions")
             |> json_response(200)

    assert contract_id == fixture.ids.access_contract
  end

  defp grant_admin!(fixture) do
    ReviewsFixtures.grant_moderator!(
      %{ids: %{polo: fixture.polo.id}, scope: fixture.service_scope},
      role_key: "admin"
    )
  end

  defp captured_subscription!(fixture, overrides \\ %{}) do
    checkout_overrides = %{
      idempotency_key:
        Map.get(overrides, :checkout_idempotency_key, "checkout-#{Ecto.UUID.generate()}")
    }

    assert {:ok, order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture, checkout_overrides)
             )

    settlement_overrides =
      Map.take(overrides, [:external_event_id, :provider_reference, :occurred_at])

    assert {:ok, contract} =
             Billing.settle_payment(
               fixture.service_scope,
               BillingFixtures.settled_payment(fixture, order, settlement_overrides)
             )

    {order, contract}
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session.token
  end
end
