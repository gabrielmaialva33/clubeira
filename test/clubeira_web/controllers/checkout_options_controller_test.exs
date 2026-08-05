defmodule ClubeiraWeb.CheckoutOptionsControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  import Ecto.Query

  alias Clubeira.Accounts
  alias Clubeira.BillingFixtures
  alias Clubeira.Factory
  alias Clubeira.Polos.PoloPlace
  alias Clubeira.Repo

  @password "uma-senha-forte-para-checkout-options"

  test "a public checkout option can be used by an authenticated member", %{conn: conn} do
    fixture = BillingFixtures.create!()

    response =
      conn
      |> get("/api/v1/polos/#{fixture.polo_route.slug}/checkout-options")
      |> json_response(200)

    assert %{
             "data" => %{
               "polo" => %{"id" => polo_id, "slug" => polo_slug},
               "options" => [option]
             },
             "meta" => %{
               "page" => %{"limit" => 20, "has_more" => false, "next_cursor" => nil}
             }
           } = response

    assert polo_id == fixture.polo.id
    assert polo_slug == fixture.polo_route.slug

    assert option == %{
             "product_offering_version_id" => fixture.offering_version.id,
             "offering_price_id" => fixture.price.id,
             "name" => fixture.offering_version.name,
             "description" => fixture.offering_version.description,
             "cycle" => %{
               "policy" => fixture.offering_version.cycle_policy,
               "interval_unit" => fixture.offering_version.cycle_interval_unit,
               "interval_count" => fixture.offering_version.cycle_interval_count
             },
             "renewal_policy" => fixture.offering_version.renewal_policy,
             "price" => %{
               "key" => fixture.price.price_key,
               "currency" => fixture.price.currency,
               "amount" => Decimal.to_string(fixture.price.amount, :normal),
               "billing_model" => fixture.price.billing_model,
               "interval_unit" => fixture.price.billing_interval_unit,
               "interval_count" => fixture.price.billing_interval_count,
               "installments" => fixture.price.installments
             }
           }

    assert {:ok, _credential} = Accounts.set_password(fixture.user, @password)
    assert {:ok, session} = Accounts.login(fixture.user.email, @password)

    checkout =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{session.token}")
      |> put_req_header("idempotency-key", "checkout-from-public-option")
      |> post(~p"/api/v1/polos/#{polo_slug}/orders", %{
        "product_offering_version_id" => option["product_offering_version_id"],
        "offering_price_id" => option["offering_price_id"]
      })
      |> json_response(201)

    assert checkout["data"]["status"] == "awaiting_payment"
    assert checkout["data"]["currency"] == option["price"]["currency"]
    assert checkout["data"]["total_amount"] == option["price"]["amount"]
  end

  test "does not advertise an option that cannot provision its entitlements", %{conn: conn} do
    fixture = BillingFixtures.create!()

    assert {:ok, {1, nil}} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               result =
                 repo.update_all(
                   from(polo_place in PoloPlace, where: polo_place.id == ^fixture.polo_place.id),
                   set: [status: "suspended"]
                 )

               {:ok, result}
             end)

    assert conn
           |> get("/api/v1/polos/#{fixture.polo_route.slug}/checkout-options")
           |> json_response(200)
           |> get_in(["data", "options"]) == []
  end

  test "paginates checkout options by an opaque price cursor", %{conn: conn} do
    fixture = BillingFixtures.create!()

    assert {:ok, second_price} =
             Repo.transact_in_polo(fixture.service_scope, fn _repo ->
               {:ok,
                Factory.insert(:offering_price,
                  polo: fixture.polo,
                  product_offering_version: fixture.offering_version,
                  price_key: "annual",
                  amount: Decimal.new("299.00")
                )}
             end)

    first_page =
      conn
      |> get("/api/v1/polos/#{fixture.polo_route.slug}/checkout-options?limit=1")
      |> json_response(200)

    assert %{
             "data" => %{"options" => [%{"offering_price_id" => first_price_id}]},
             "meta" => %{
               "page" => %{"limit" => 1, "has_more" => true, "next_cursor" => cursor}
             }
           } = first_page

    assert first_price_id == fixture.price.id
    assert is_binary(cursor)
    refute cursor =~ fixture.price.id

    second_page =
      conn
      |> recycle()
      |> get("/api/v1/polos/#{fixture.polo_route.slug}/checkout-options?limit=1&after=#{cursor}")
      |> json_response(200)

    assert %{
             "data" => %{"options" => [%{"offering_price_id" => second_price_id}]},
             "meta" => %{
               "page" => %{"limit" => 1, "has_more" => false, "next_cursor" => nil}
             }
           } = second_page

    assert second_price_id == second_price.id
  end

  test "keeps checkout options isolated to the routed polo", %{conn: conn} do
    fixture = BillingFixtures.create!()
    other_fixture = BillingFixtures.create!()

    response =
      conn
      |> get("/api/v1/polos/#{fixture.polo_route.slug}/checkout-options")
      |> json_response(200)

    assert response
           |> get_in(["data", "options"])
           |> Enum.map(&{&1["product_offering_version_id"], &1["offering_price_id"]}) ==
             [{fixture.offering_version.id, fixture.price.id}]

    encoded = Jason.encode!(response)
    refute encoded =~ other_fixture.offering_version.id
    refute encoded =~ other_fixture.price.id
  end
end
