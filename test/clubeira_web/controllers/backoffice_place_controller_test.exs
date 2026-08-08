defmodule ClubeiraWeb.BackofficePlaceControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  @password "uma-senha-forte-para-inventario-de-lugares"

  test "an admin rediscovers an onboarded place before its public profile exists", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    token = authenticate!(admin_scope.actor_user_id)

    response =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get(inventory_path(fixture))
      |> json_response(200)

    assert %{
             "data" => [
               %{
                 "polo_place_id" => polo_place_id,
                 "status" => "active",
                 "recorded_at" => recorded_at,
                 "participation" => %{
                   "starts_at" => starts_at,
                   "ends_at" => nil
                 },
                 "place" => %{
                   "id" => place_id,
                   "name" => place_name,
                   "slug" => place_slug,
                   "status" => "active",
                   "timezone" => "America/Sao_Paulo"
                 },
                 "profile" => nil
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

    assert polo_place_id == fixture.ids.polo_place
    assert place_id == fixture.ids.place
    assert is_binary(place_name)
    assert is_binary(place_slug)
    refute inspect(response) =~ "cnpj"

    for timestamp <- [recorded_at, starts_at] do
      assert {:ok, _datetime, 0} = DateTime.from_iso8601(timestamp)
    end
  end

  test "the inventory paginates participations and filters operational state", %{conn: conn} do
    fixture =
      RedemptionsFixtures.create!(
        alternate_validation_place: true,
        polo_place_status: "suspended"
      )

    other_polo = RedemptionsFixtures.create!()
    profile_id = insert_profile!(fixture, fixture.ids.other_polo_place)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    token = authenticate!(admin_scope.actor_user_id)
    path = inventory_path(fixture)

    assert %{
             "data" => [%{"polo_place_id" => first_id}],
             "meta" => %{
               "count" => 1,
               "page" => %{"limit" => 1, "has_more" => true, "next_cursor" => cursor}
             }
           } =
             conn
             |> put_req_header("authorization", "Bearer #{token}")
             |> get(path <> "?limit=1")
             |> json_response(200)

    assert is_binary(cursor)
    refute cursor =~ first_id

    assert %{
             "data" => [%{"polo_place_id" => second_id}],
             "meta" => %{
               "count" => 1,
               "page" => %{"limit" => 1, "has_more" => false, "next_cursor" => nil}
             }
           } =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> get(path <> "?limit=1&after=#{cursor}")
             |> json_response(200)

    assert MapSet.new([first_id, second_id]) ==
             MapSet.new([fixture.ids.polo_place, fixture.ids.other_polo_place])

    assert %{"data" => [%{"polo_place_id" => suspended_id}]} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> get(path <> "?status=suspended")
             |> json_response(200)

    assert suspended_id == fixture.ids.polo_place

    assert %{"data" => [%{"polo_place_id" => missing_profile_id}]} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> get(path <> "?profile_status=missing")
             |> json_response(200)

    assert missing_profile_id == fixture.ids.polo_place

    assert %{
             "data" => [
               %{
                 "polo_place_id" => published_participation_id,
                 "profile" => %{
                   "id" => ^profile_id,
                   "revision" => 1,
                   "public_email" => "operacao@example.test",
                   "public_phone" => "+5511999990000",
                   "updated_at" => updated_at
                 }
               }
             ]
           } =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> get(path <> "?profile_status=published&place_id=#{fixture.ids.other_place}")
             |> json_response(200)

    assert published_participation_id == fixture.ids.other_polo_place
    assert {:ok, _updated_at, 0} = DateTime.from_iso8601(updated_at)

    assert %{"data" => []} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> get(path <> "?place_id=#{other_polo.ids.place}")
             |> json_response(200)
  end

  test "the inventory enforces polo capability and validates every filter", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    other_polo = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)
    admin_token = authenticate!(admin_scope.actor_user_id)
    moderator_token = authenticate!(moderator_scope.actor_user_id)
    path = inventory_path(fixture)

    assert conn
           |> put_req_header("authorization", "Bearer #{moderator_token}")
           |> get(path)
           |> json_response(403) == %{"errors" => %{"detail" => "Forbidden"}}

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> get(inventory_path(other_polo))
           |> json_response(403) == %{"errors" => %{"detail" => "Forbidden"}}

    for query <- ["after=not-a-cursor", "limit=0", "limit=101"] do
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(path <> "?#{query}")
             |> json_response(400) == %{"errors" => %{"detail" => "Bad Request"}}
    end

    for query <- [
          "place_id=not-a-uuid",
          "profile_status=unknown",
          "status=unknown"
        ] do
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(path <> "?#{query}")
             |> json_response(422) == %{
               "errors" => %{"detail" => "Unprocessable Content"}
             }
    end
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session.token
  end

  defp insert_profile!(fixture, polo_place_id) do
    profile_id = Ecto.UUID.generate(version: 7, precision: :monotonic)

    assert %{num_rows: 1} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               INSERT INTO polo_place_profiles (
                 id,
                 polo_id,
                 polo_place_id,
                 public_email,
                 public_phone,
                 revision
               )
               VALUES ($1, $2, $3, 'operacao@example.test', '+5511999990000', 1)
               """,
               [profile_id, fixture.ids.polo, polo_place_id]
             )

    profile_id
  end

  defp inventory_path(fixture) do
    "/api/v1/polos/#{fixture.polo_slug}/backoffice/places"
  end
end
