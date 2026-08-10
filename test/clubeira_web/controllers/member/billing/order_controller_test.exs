defmodule ClubeiraWeb.Member.OrderControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Billing
  alias Clubeira.BillingFixtures
  alias Clubeira.Factory
  alias Clubeira.Tenancy.Scope

  @password "uma-senha-forte-para-historico-de-pedidos"

  test "an authenticated member lists an order with its historical item", %{conn: conn} do
    fixture = BillingFixtures.create!()
    token = authenticate!(fixture)

    created =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("idempotency-key", "order-history-api-001")
      |> post(~p"/api/v1/polos/#{fixture.polo_route.slug}/orders", %{
        "product_offering_version_id" => fixture.offering_version.id,
        "offering_price_id" => fixture.price.id
      })
      |> json_response(201)
      |> get_in(["data"])

    response =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/api/v1/polos/#{fixture.polo_route.slug}/me/orders")
      |> json_response(200)

    assert %{
             "data" => [
               %{
                 "id" => order_id,
                 "order_number" => order_number,
                 "status" => "awaiting_payment",
                 "currency" => currency,
                 "subtotal_amount" => subtotal_amount,
                 "discount_amount" => discount_amount,
                 "total_amount" => total_amount,
                 "placed_at" => placed_at,
                 "cancelled_at" => nil,
                 "items" => [
                   %{
                     "id" => item_id,
                     "product_offering_version_id" => offering_version_id,
                     "offering_price_id" => offering_price_id,
                     "name" => offering_name,
                     "description" => offering_description,
                     "quantity" => 1,
                     "unit_amount" => unit_amount,
                     "total_amount" => item_total_amount
                   }
                 ]
               }
             ],
             "meta" => %{
               "count" => 1,
               "page" => %{
                 "limit" => 20,
                 "has_more" => false,
                 "next_cursor" => nil
               }
             }
           } = response

    assert order_id == created["id"]
    assert order_number == created["order_number"]
    assert currency == fixture.price.currency
    assert offering_version_id == fixture.offering_version.id
    assert offering_price_id == fixture.price.id
    assert offering_name == fixture.offering_version.name
    assert offering_description == fixture.offering_version.description
    assert {:ok, ^item_id} = Ecto.UUID.cast(item_id)
    assert {:ok, _placed_at, 0} = DateTime.from_iso8601(placed_at)
    assert Decimal.equal?(Decimal.new(discount_amount), Decimal.new(0))

    for amount <- [subtotal_amount, total_amount, unit_amount, item_total_amount] do
      assert Decimal.equal?(Decimal.new(amount), fixture.price.amount)
    end
  end

  test "an authenticated member cannot list another member's order", %{conn: conn} do
    fixture = BillingFixtures.create!()
    token = authenticate!(fixture)

    assert {:ok, own_order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture, idempotency_key: "order-history-owner")
             )

    another_user = Factory.insert(:user)

    another_scope =
      Scope.new!(fixture.polo.id,
        actor_user_id: another_user.id,
        request_id: Ecto.UUID.generate(version: 7)
      )

    assert {:ok, another_order} =
             Billing.place_order(
               another_scope,
               BillingFixtures.checkout_request(fixture,
                 idempotency_key: "order-history-another-member"
               )
             )

    response =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/api/v1/polos/#{fixture.polo_route.slug}/me/orders")
      |> json_response(200)

    assert [%{"id" => own_order_id}] = response["data"]
    assert own_order_id == own_order.id
    refute inspect(response) =~ another_order.id
  end

  test "orders stay isolated to the routed polo for the same member", %{conn: conn} do
    first = BillingFixtures.create!()
    second = BillingFixtures.create!()
    token = authenticate!(first)

    assert {:ok, first_order} =
             Billing.place_order(
               first.member_scope,
               BillingFixtures.checkout_request(first,
                 idempotency_key: "order-history-first-polo"
               )
             )

    second_scope =
      Scope.new!(second.polo.id,
        actor_user_id: first.user.id,
        request_id: Ecto.UUID.generate(version: 7)
      )

    assert {:ok, second_order} =
             Billing.place_order(
               second_scope,
               BillingFixtures.checkout_request(second,
                 idempotency_key: "order-history-second-polo"
               )
             )

    response =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/api/v1/polos/#{first.polo_route.slug}/me/orders")
      |> json_response(200)

    assert [%{"id" => first_order_id}] = response["data"]
    assert first_order_id == first_order.id
    refute inspect(response) =~ second_order.id
  end

  test "orders paginate newest first with an opaque cursor", %{conn: conn} do
    fixture = BillingFixtures.create!()
    token = authenticate!(fixture)

    assert {:ok, older_order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture, idempotency_key: "order-history-older")
             )

    assert {:ok, newer_order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture, idempotency_key: "order-history-newer")
             )

    first_page =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/api/v1/polos/#{fixture.polo_route.slug}/me/orders?limit=1")
      |> json_response(200)

    assert %{
             "data" => [%{"id" => newer_order_id}],
             "meta" => %{
               "count" => 1,
               "page" => %{
                 "limit" => 1,
                 "has_more" => true,
                 "next_cursor" => cursor
               }
             }
           } = first_page

    assert newer_order_id == newer_order.id
    assert is_binary(cursor)
    refute cursor =~ newer_order.id

    second_page =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/api/v1/polos/#{fixture.polo_route.slug}/me/orders?limit=1&after=#{cursor}")
      |> json_response(200)

    assert %{
             "data" => [%{"id" => older_order_id}],
             "meta" => %{
               "count" => 1,
               "page" => %{
                 "limit" => 1,
                 "has_more" => false,
                 "next_cursor" => nil
               }
             }
           } = second_page

    assert older_order_id == older_order.id
  end

  test "the order status reflects an atomic payment settlement", %{conn: conn} do
    fixture = BillingFixtures.create!()
    token = authenticate!(fixture)

    assert {:ok, order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture, idempotency_key: "order-history-status")
             )

    path = "/api/v1/polos/#{fixture.polo_route.slug}/me/orders"

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> get(path)
           |> json_response(200)
           |> get_in(["data", Access.at(0), "status"]) == "awaiting_payment"

    assert {:ok, _contract} =
             Billing.settle_payment(
               fixture.service_scope,
               BillingFixtures.settled_payment(fixture, order)
             )

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{token}")
           |> get(path)
           |> json_response(200)
           |> get_in(["data", Access.at(0), "status"]) == "paid"
  end

  test "order history requires an authenticated bearer session", %{conn: conn} do
    assert conn
           |> get("/api/v1/polos/unknown-polo/me/orders")
           |> json_response(401) == %{"errors" => %{"detail" => "Unauthorized"}}
  end

  test "order history rejects invalid pagination", %{conn: conn} do
    fixture = BillingFixtures.create!()
    token = authenticate!(fixture)
    path = "/api/v1/polos/#{fixture.polo_route.slug}/me/orders"

    for query <- ["limit=0", "after=invalid"] do
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> get("#{path}?#{query}")
             |> json_response(400) == %{"errors" => %{"detail" => "Bad Request"}}
    end
  end

  defp authenticate!(fixture) do
    assert {:ok, _credential} = Accounts.set_password(fixture.user, @password)
    assert {:ok, session} = Accounts.login(fixture.user.email, @password)
    session.token
  end
end
