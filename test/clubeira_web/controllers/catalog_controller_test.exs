defmodule ClubeiraWeb.CatalogControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.Factory
  alias Clubeira.RedemptionsFixtures

  test "GET /api/v1/polos/:slug/catalog returns only that polo's published catalog", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    other_fixture = RedemptionsFixtures.create!()

    conn = get(conn, ~p"/api/v1/polos/#{fixture.polo_slug}/catalog")

    assert %{
             "data" => %{
               "polo" => %{
                 "id" => polo_id,
                 "slug" => polo_slug,
                 "name" => polo_name,
                 "timezone" => "America/Sao_Paulo"
               },
               "offers" => [offer]
             }
           } = json_response(conn, 200)

    assert polo_id == fixture.ids.polo
    assert polo_slug == fixture.polo_slug
    assert polo_name == "Polo #{short_suffix(fixture.ids.polo)}"

    assert %{
             "meta" => %{
               "page" => %{"limit" => 20, "has_more" => false, "next_cursor" => nil}
             }
           } = json_response(conn, 200)

    assert offer == %{
             "offer_id" => fixture.ids.benefit_offer,
             "offer_version_id" => fixture.ids.benefit_offer_version,
             "version" => 1,
             "code" => "offer-#{short_suffix(fixture.ids.polo)}",
             "name" => "Benefício #{short_suffix(fixture.ids.polo)}",
             "title" => "Benefício de teste",
             "description" => "Descrição do benefício",
             "terms" => "Uso único",
             "redemption_instructions" => "Apresente no caixa",
             "benefit" => %{
               "kind" => "complimentary_item",
               "percentage" => nil,
               "amount" => nil,
               "currency" => nil
             },
             "effective_during" => %{
               "starts_at" => DateTime.to_iso8601(DateTime.add(fixture.now, -3_600)),
               "ends_at" => nil
             },
             "places" => [
               %{
                 "polo_place_id" => fixture.ids.polo_place,
                 "place_id" => fixture.ids.place,
                 "slug" => "place-#{short_suffix(fixture.ids.polo)}",
                 "name" => "Parceiro #{short_suffix(fixture.ids.polo)}"
               }
             ]
           }

    response_body = response(conn, 200)
    refute response_body =~ other_fixture.ids.polo
    refute response_body =~ other_fixture.ids.benefit_offer
    refute response_body =~ other_fixture.ids.place
  end

  test "catalog groups every active place under each offer without duplicating offers", %{
    conn: conn
  } do
    fixture =
      RedemptionsFixtures.create!(
        additional_offer: true,
        alternate_validation_place: true
      )

    response =
      conn
      |> get(~p"/api/v1/polos/#{fixture.polo_slug}/catalog")
      |> json_response(200)

    assert %{"data" => %{"offers" => offers}} = response
    assert length(offers) == 2

    assert %{"places" => places} =
             Enum.find(offers, &(&1["offer_id"] == fixture.ids.benefit_offer))

    assert MapSet.new(Enum.map(places, & &1["polo_place_id"])) ==
             MapSet.new([fixture.ids.polo_place, fixture.ids.other_polo_place])

    assert %{"places" => [%{"polo_place_id" => polo_place_id}]} =
             Enum.find(offers, &(&1["offer_id"] == fixture.ids.other_benefit_offer))

    assert polo_place_id == fixture.ids.polo_place
  end

  test "catalog paginates offers by opaque cursor without truncating their places", %{conn: conn} do
    fixture =
      RedemptionsFixtures.create!(
        additional_offer: true,
        alternate_validation_place: true
      )

    first_page =
      conn
      |> get(~p"/api/v1/polos/#{fixture.polo_slug}/catalog?limit=1")
      |> json_response(200)

    assert %{
             "data" => %{"offers" => [first_offer]},
             "meta" => %{
               "page" => %{"limit" => 1, "has_more" => true, "next_cursor" => cursor}
             }
           } = first_page

    assert first_offer["offer_version_id"] == fixture.ids.benefit_offer_version
    assert length(first_offer["places"]) == 2
    assert is_binary(cursor)
    refute cursor =~ fixture.ids.benefit_offer_version

    second_page =
      conn
      |> recycle()
      |> get(~p"/api/v1/polos/#{fixture.polo_slug}/catalog?limit=1&after=#{cursor}")
      |> json_response(200)

    assert %{
             "data" => %{"offers" => [second_offer]},
             "meta" => %{
               "page" => %{"limit" => 1, "has_more" => false, "next_cursor" => nil}
             }
           } = second_page

    assert second_offer["offer_version_id"] == fixture.ids.other_benefit_offer_version
  end

  test "catalog rejects malformed cursors and limits", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    path = "/api/v1/polos/#{fixture.polo_slug}/catalog"
    expected = %{"errors" => %{"detail" => "Bad Request"}}

    assert conn |> get(path <> "?limit=0") |> json_response(400) == expected
    assert conn |> recycle() |> get(path <> "?limit=101") |> json_response(400) == expected
    assert conn |> recycle() |> get(path <> "?limit=muitos") |> json_response(400) == expected

    assert conn |> recycle() |> get(path <> "?after=nao-e-cursor") |> json_response(400) ==
             expected
  end

  test "catalog omits inactive offers without hiding the active polo", %{conn: conn} do
    fixture = RedemptionsFixtures.create!(offer_status: "retired")

    conn = get(conn, ~p"/api/v1/polos/#{fixture.polo_slug}/catalog")

    assert %{"data" => %{"polo" => %{"id" => polo_id}, "offers" => []}} =
             json_response(conn, 200)

    assert polo_id == fixture.ids.polo
  end

  test "catalog omits unpublished and non-current offer versions", %{conn: conn} do
    draft = RedemptionsFixtures.create!(offer_version_status: "draft")
    now = DateTime.utc_now(:microsecond)

    expired =
      RedemptionsFixtures.create!(
        offer_effective_during:
          Factory.tstz_range(DateTime.add(now, -7_200), DateTime.add(now, -3_600))
      )

    assert conn
           |> get(~p"/api/v1/polos/#{draft.polo_slug}/catalog")
           |> json_response(200)
           |> get_in(["data", "offers"]) == []

    assert conn
           |> recycle()
           |> get(~p"/api/v1/polos/#{expired.polo_slug}/catalog")
           |> json_response(200)
           |> get_in(["data", "offers"]) == []
  end

  test "catalog omits unavailable polo places and inactive global places", %{conn: conn} do
    suspended = RedemptionsFixtures.create!(polo_place_status: "suspended")
    inactive_place = RedemptionsFixtures.create!(place_status: "retired")
    now = DateTime.utc_now(:microsecond)

    expired_participation =
      RedemptionsFixtures.create!(
        participation_during:
          Factory.tstz_range(DateTime.add(now, -7_200), DateTime.add(now, -3_600))
      )

    for fixture <- [suspended, inactive_place, expired_participation] do
      assert conn
             |> recycle()
             |> get(~p"/api/v1/polos/#{fixture.polo_slug}/catalog")
             |> json_response(200)
             |> get_in(["data", "offers"]) == []
    end
  end

  test "public catalog advertises an offer independently of redemption schedules", %{conn: conn} do
    fixture =
      RedemptionsFixtures.create!(
        blackout: true,
        outside_availability_window: true
      )

    assert conn
           |> get(~p"/api/v1/polos/#{fixture.polo_slug}/catalog")
           |> json_response(200)
           |> get_in(["data", "offers"])
           |> Enum.map(& &1["offer_id"]) == [fixture.ids.benefit_offer]
  end

  test "catalog serializes exact decimal benefit values as strings", %{conn: conn} do
    fixture =
      RedemptionsFixtures.create!(
        benefit_kind: "discount_percentage",
        percentage_value: Decimal.new("12.5000")
      )

    conn = get(conn, ~p"/api/v1/polos/#{fixture.polo_slug}/catalog")

    assert %{
             "data" => %{
               "offers" => [
                 %{
                   "benefit" => %{
                     "kind" => "discount_percentage",
                     "percentage" => "12.5000",
                     "amount" => nil,
                     "currency" => nil
                   }
                 }
               ]
             }
           } = json_response(conn, 200)
  end

  test "catalog does not expose suspended polos", %{conn: conn} do
    fixture = RedemptionsFixtures.create!(polo_status: "suspended")

    conn = get(conn, ~p"/api/v1/polos/#{fixture.polo_slug}/catalog")

    assert json_response(conn, 404) == %{"errors" => %{"detail" => "Not Found"}}
  end

  test "unknown and malformed routes have the same not-found response", %{conn: conn} do
    expected = %{"errors" => %{"detail" => "Not Found"}}

    assert conn
           |> get(~p"/api/v1/polos/polo-inexistente/catalog")
           |> json_response(404) == expected

    assert conn
           |> recycle()
           |> get(~p"/api/v1/polos/INVALID/catalog")
           |> json_response(404) == expected
  end

  defp short_suffix(id), do: id |> String.replace("-", "") |> String.slice(-12, 12)
end
