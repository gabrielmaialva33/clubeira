defmodule ClubeiraWeb.Member.CheckoutControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.BillingFixtures

  @password "uma-senha-de-checkout-forte"

  test "an authenticated member places an order with authoritative server pricing", %{conn: conn} do
    fixture = BillingFixtures.create!()
    token = authenticate!(fixture)

    response =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("idempotency-key", "checkout-api-001")
      |> post(~p"/api/v1/polos/#{fixture.polo_route.slug}/orders", %{
        "product_offering_version_id" => fixture.offering_version.id,
        "offering_price_id" => fixture.price.id,
        "amount" => "0.01",
        "currency" => "USD"
      })
      |> json_response(201)

    assert %{
             "data" => %{
               "id" => order_id,
               "order_number" => "CLB-" <> _,
               "status" => "awaiting_payment",
               "currency" => currency,
               "subtotal_amount" => subtotal_amount,
               "discount_amount" => "0",
               "total_amount" => total_amount,
               "placed_at" => placed_at
             }
           } = response

    assert {:ok, ^order_id} = Ecto.UUID.cast(order_id)
    assert currency == fixture.price.currency
    assert Decimal.equal?(Decimal.new(subtotal_amount), fixture.price.amount)
    assert Decimal.equal?(Decimal.new(total_amount), fixture.price.amount)
    assert {:ok, _placed_at, 0} = DateTime.from_iso8601(placed_at)
  end

  test "reusing an idempotency key for another checkout returns conflict", %{conn: conn} do
    fixture = BillingFixtures.create!()
    token = authenticate!(fixture)
    idempotency_key = "checkout-api-conflict"

    request = %{
      "product_offering_version_id" => fixture.offering_version.id,
      "offering_price_id" => fixture.price.id
    }

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", idempotency_key)
           |> post(~p"/api/v1/polos/#{fixture.polo_route.slug}/orders", request)
           |> json_response(201)

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", idempotency_key)
           |> post(
             ~p"/api/v1/polos/#{fixture.polo_route.slug}/orders",
             Map.put(request, "offering_price_id", Ecto.UUID.generate())
           )
           |> json_response(409) == %{"errors" => %{"detail" => "Conflict"}}
  end

  test "replaying the same checkout returns the original order", %{conn: conn} do
    fixture = BillingFixtures.create!()
    token = authenticate!(fixture)
    idempotency_key = "checkout-api-replay"

    request = %{
      "product_offering_version_id" => fixture.offering_version.id,
      "offering_price_id" => fixture.price.id
    }

    first =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("idempotency-key", idempotency_key)
      |> post(~p"/api/v1/polos/#{fixture.polo_route.slug}/orders", request)
      |> json_response(201)

    replayed =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("idempotency-key", idempotency_key)
      |> post(~p"/api/v1/polos/#{fixture.polo_route.slug}/orders", request)
      |> json_response(201)

    assert replayed["data"]["id"] == first["data"]["id"]
  end

  test "checkout requires exactly one idempotency key header", %{conn: conn} do
    fixture = BillingFixtures.create!()
    token = authenticate!(fixture)

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> post(~p"/api/v1/polos/#{fixture.polo_route.slug}/orders", %{
             "product_offering_version_id" => fixture.offering_version.id,
             "offering_price_id" => fixture.price.id
           })
           |> json_response(422) == %{"errors" => %{"detail" => "Unprocessable Content"}}
  end

  test "invalid checkout input does not consume the idempotency key", %{conn: conn} do
    fixture = BillingFixtures.create!()
    token = authenticate!(fixture)
    idempotency_key = "checkout-api-validation"

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", idempotency_key)
           |> post(~p"/api/v1/polos/#{fixture.polo_route.slug}/orders", %{})
           |> json_response(422) == %{"errors" => %{"detail" => "Unprocessable Content"}}

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", idempotency_key)
           |> post(~p"/api/v1/polos/#{fixture.polo_route.slug}/orders", %{
             "product_offering_version_id" => fixture.offering_version.id,
             "offering_price_id" => fixture.price.id
           })
           |> json_response(201)
  end

  test "checkout returns not found for an unknown polo route", %{conn: conn} do
    fixture = BillingFixtures.create!()
    token = authenticate!(fixture)

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", "checkout-api-unknown-polo")
           |> post(~p"/api/v1/polos/unknown-polo/orders", %{
             "product_offering_version_id" => fixture.offering_version.id,
             "offering_price_id" => fixture.price.id
           })
           |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}
  end

  test "checkout rejects commercial identifiers from another polo", %{conn: conn} do
    fixture = BillingFixtures.create!()
    other_polo = BillingFixtures.create!()
    token = authenticate!(fixture)

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", "checkout-api-cross-polo")
           |> post(~p"/api/v1/polos/#{fixture.polo_route.slug}/orders", %{
             "product_offering_version_id" => other_polo.offering_version.id,
             "offering_price_id" => other_polo.price.id
           })
           |> json_response(422) == %{"errors" => %{"detail" => "Unprocessable Content"}}
  end

  test "checkout requires an authenticated bearer session", %{conn: conn} do
    assert conn
           |> put_req_header("idempotency-key", "checkout-api-unauthenticated")
           |> post(~p"/api/v1/polos/unknown-polo/orders", %{})
           |> json_response(401) == %{"errors" => %{"detail" => "Unauthorized"}}
  end

  defp authenticate!(fixture) do
    assert {:ok, _credential} = Accounts.set_password(fixture.user, @password)
    assert {:ok, session} = Accounts.login(fixture.user.email, @password)
    session.token
  end
end
