defmodule ClubeiraWeb.PlaceControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  import Ecto.Query

  alias Clubeira.Directory.Address
  alias Clubeira.Directory.Place
  alias Clubeira.Factory
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo

  test "a visitor lists an active partner with its public directory data", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    place = Repo.get!(Place, fixture.ids.place)

    Repo.update_all(
      from(address in Address, where: address.id == ^fixture.ids.address),
      set: [latitude: Decimal.new("-3.731862"), longitude: Decimal.new("-40.991965")]
    )

    brand =
      Factory.insert(:brand,
        slug: "marca-sobral",
        name: "Marca Sobral"
      )

    operator =
      Factory.insert(:organization,
        legal_name: "Parceiro Sobral Ltda.",
        trade_name: "Parceiro Sobral"
      )

    Factory.insert(:place_brand, place: place, brand: brand)
    Factory.insert(:place_operator, place: place, organization: operator)

    response =
      conn
      |> get("/api/v1/polos/#{fixture.polo_slug}/places")
      |> json_response(200)

    assert %{
             "data" => %{
               "polo" => %{
                 "id" => polo_id,
                 "slug" => polo_slug,
                 "name" => polo_name,
                 "timezone" => "America/Sao_Paulo"
               },
               "places" => [
                 %{
                   "polo_place_id" => polo_place_id,
                   "place_id" => place_id,
                   "slug" => place_slug,
                   "name" => place_name,
                   "timezone" => "America/Sao_Paulo",
                   "address" => %{
                     "street" => "Rua do Resgate",
                     "number" => "1",
                     "complement" => nil,
                     "district" => "Centro",
                     "postal_code" => nil,
                     "latitude" => "-3.731862",
                     "longitude" => "-40.991965",
                     "city" => %{
                       "id" => city_id,
                       "name" => city_name,
                       "country_code" => "BR",
                       "subdivision_code" => "BR-SP",
                       "timezone" => "America/Sao_Paulo"
                     }
                   },
                   "brands" => [
                     %{
                       "id" => brand_id,
                       "slug" => "marca-sobral",
                       "name" => "Marca Sobral",
                       "role" => "primary"
                     }
                   ],
                   "operators" => [
                     %{
                       "organization_id" => operator_id,
                       "trade_name" => "Parceiro Sobral",
                       "role" => "operator"
                     }
                   ]
                 }
               ]
             },
             "meta" => %{
               "page" => %{
                 "limit" => 20,
                 "has_more" => false,
                 "next_cursor" => nil
               }
             }
           } = response

    assert polo_id == fixture.ids.polo
    assert polo_slug == fixture.polo_slug
    assert polo_name == "Polo #{short_suffix(fixture.ids.polo)}"
    assert polo_place_id == fixture.ids.polo_place
    assert place_id == fixture.ids.place
    assert place_slug == "place-#{short_suffix(fixture.ids.polo)}"
    assert place_name == "Parceiro #{short_suffix(fixture.ids.polo)}"
    assert city_id == fixture.ids.city
    assert city_name == "Cidade #{short_suffix(fixture.ids.polo)}"
    assert brand_id == brand.id
    assert operator_id == operator.id
  end

  test "the public directory hides inactive places and suspended participations", %{conn: conn} do
    inactive_place = RedemptionsFixtures.create!(place_status: "inactive")
    suspended_participation = RedemptionsFixtures.create!(polo_place_status: "suspended")

    for fixture <- [inactive_place, suspended_participation] do
      assert conn
             |> recycle()
             |> get("/api/v1/polos/#{fixture.polo_slug}/places")
             |> json_response(200)
             |> get_in(["data", "places"]) == []
    end
  end

  test "the public directory keeps places isolated to the routed polo", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    other_fixture = RedemptionsFixtures.create!()

    response =
      conn
      |> get("/api/v1/polos/#{fixture.polo_slug}/places")
      |> json_response(200)

    assert [%{"place_id" => place_id}] = get_in(response, ["data", "places"])
    assert place_id == fixture.ids.place
    refute inspect(response) =~ other_fixture.ids.polo
    refute inspect(response) =~ other_fixture.ids.place
  end

  test "the public directory omits inactive brands and operators", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    place = Repo.get!(Place, fixture.ids.place)
    brand = Factory.insert(:brand, status: "inactive")
    operator = Factory.insert(:organization, status: "suspended")

    Factory.insert(:place_brand, place: place, brand: brand)
    Factory.insert(:place_operator, place: place, organization: operator)

    assert %{"brands" => [], "operators" => []} =
             conn
             |> get("/api/v1/polos/#{fixture.polo_slug}/places")
             |> json_response(200)
             |> get_in(["data", "places", Access.at(0)])
  end

  test "the public directory paginates places without truncating their brands", %{conn: conn} do
    fixture = RedemptionsFixtures.create!(alternate_validation_place: true)
    [first_place_id, second_place_id] = Enum.sort([fixture.ids.place, fixture.ids.other_place])
    first_place = Repo.get!(Place, first_place_id)

    primary_brand = Factory.insert(:brand, slug: "marca-principal", name: "Marca Principal")
    co_brand = Factory.insert(:brand, slug: "marca-parceira", name: "Marca Parceira")

    Factory.insert(:place_brand, place: first_place, brand: primary_brand)
    Factory.insert(:place_brand, place: first_place, brand: co_brand, role: "co_brand")

    first_page =
      conn
      |> get("/api/v1/polos/#{fixture.polo_slug}/places?limit=1")
      |> json_response(200)

    assert %{
             "data" => %{
               "places" => [
                 %{
                   "place_id" => returned_first_place_id,
                   "brands" => brands
                 }
               ]
             },
             "meta" => %{
               "page" => %{
                 "limit" => 1,
                 "has_more" => true,
                 "next_cursor" => cursor
               }
             }
           } = first_page

    assert returned_first_place_id == first_place_id
    assert MapSet.new(Enum.map(brands, & &1["id"])) ==
             MapSet.new([primary_brand.id, co_brand.id])

    assert is_binary(cursor)
    refute cursor =~ first_place_id

    second_page =
      conn
      |> recycle()
      |> get("/api/v1/polos/#{fixture.polo_slug}/places?limit=1&after=#{cursor}")
      |> json_response(200)

    assert %{
             "data" => %{"places" => [%{"place_id" => returned_second_place_id}]},
             "meta" => %{
               "page" => %{
                 "limit" => 1,
                 "has_more" => false,
                 "next_cursor" => nil
               }
             }
           } = second_page

    assert returned_second_place_id == second_place_id
  end

  test "the public directory rejects invalid pagination", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    path = "/api/v1/polos/#{fixture.polo_slug}/places"

    for query <- ["limit=0", "limit=101", "after=invalid"] do
      assert conn
             |> recycle()
             |> get("#{path}?#{query}")
             |> json_response(400) == %{"errors" => %{"detail" => "Bad Request"}}
    end
  end

  defp short_suffix(uuid), do: uuid |> String.replace("-", "") |> String.slice(-12, 12)
end
