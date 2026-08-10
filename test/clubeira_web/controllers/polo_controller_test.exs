defmodule ClubeiraWeb.PoloControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.RedemptionsFixtures

  test "public discovery lists only active routed polos with safe city identity", %{conn: conn} do
    active = RedemptionsFixtures.create!()
    draft = RedemptionsFixtures.create!()

    RedemptionsFixtures.scoped_query!(
      draft,
      "UPDATE polos SET status = 'draft' WHERE id = $1",
      [draft.ids.polo]
    )

    response =
      conn
      |> get("/api/v1/polos")
      |> json_response(200)

    assert %{
             "data" => [polo],
             "meta" => %{
               "count" => 1,
               "page" => %{
                 "limit" => 20,
                 "has_more" => false,
                 "next_cursor" => nil
               }
             }
           } = response

    assert polo |> Map.keys() |> Enum.sort() == ~w(city id name slug timezone)

    assert polo["id"] == active.ids.polo
    assert polo["slug"] == active.polo_slug
    assert is_binary(polo["name"])
    assert is_binary(polo["timezone"])

    assert %{
             "id" => city_id,
             "name" => city_name,
             "subdivision_code" => subdivision_code,
             "country_code" => country_code,
             "timezone" => city_timezone
           } = polo["city"]

    assert is_binary(city_id)
    assert is_binary(city_name)
    assert is_binary(subdivision_code)
    assert country_code == "BR"
    assert is_binary(city_timezone)
    refute inspect(response) =~ draft.ids.polo
  end

  test "public discovery paginates stable routes with an opaque cursor", %{conn: conn} do
    first = RedemptionsFixtures.create!()
    second = RedemptionsFixtures.create!()

    first_page =
      conn
      |> get("/api/v1/polos?limit=1")
      |> json_response(200)

    assert %{
             "data" => [first_result],
             "meta" => %{
               "page" => %{
                 "limit" => 1,
                 "has_more" => true,
                 "next_cursor" => cursor
               }
             }
           } = first_page

    second_page =
      conn
      |> recycle()
      |> get("/api/v1/polos?limit=1&after=#{cursor}")
      |> json_response(200)

    assert %{
             "data" => [second_result],
             "meta" => %{
               "page" => %{
                 "limit" => 1,
                 "has_more" => false,
                 "next_cursor" => nil
               }
             }
           } = second_page

    assert MapSet.new([first_result["id"], second_result["id"]]) ==
             MapSet.new([first.ids.polo, second.ids.polo])

    assert conn
           |> recycle()
           |> get("/api/v1/polos?after=invalid")
           |> json_response(400) == %{"errors" => %{"detail" => "Bad Request"}}
  end
end
