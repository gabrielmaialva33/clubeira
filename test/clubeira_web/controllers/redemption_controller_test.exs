defmodule ClubeiraWeb.RedemptionControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Redemptions
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.Reviews

  @password "uma-senha-forte-para-historico-de-resgates"

  test "an authenticated member lists a successful redemption with its place and benefit", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    assert {:ok, redemption} = Redemptions.confirm(fixture.scope, fixture.request)
    token = authenticate!(fixture.ids.user)

    response =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get(~p"/api/v1/polos/#{fixture.polo_slug}/me/redemptions")
      |> json_response(200)

    assert %{
             "data" => [
               %{
                 "id" => redemption_id,
                 "polo_place_id" => polo_place_id,
                 "units" => 1,
                 "redeemed_at" => redeemed_at,
                 "place" => %{
                   "id" => place_id,
                   "slug" => place_slug,
                   "name" => place_name,
                   "timezone" => "America/Sao_Paulo"
                 },
                 "benefit" => %{
                   "id" => benefit_id,
                   "version_id" => benefit_version_id,
                   "kind" => "complimentary_item",
                   "title" => "Benefício de teste",
                   "description" => "Descrição do benefício"
                 },
                 "review" => nil
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

    assert redemption_id == redemption.id
    assert polo_place_id == fixture.ids.polo_place
    assert place_id == fixture.ids.place
    assert place_slug == "place-#{suffix(fixture.ids.polo)}"
    assert place_name == "Parceiro #{suffix(fixture.ids.polo)}"
    assert benefit_id == fixture.ids.benefit_offer
    assert benefit_version_id == fixture.ids.benefit_offer_version
    assert {:ok, _redeemed_at, 0} = DateTime.from_iso8601(redeemed_at)
  end

  test "the history exposes the member's existing review for the redeemed place", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    assert {:ok, redemption} = Redemptions.confirm(fixture.scope, fixture.request)

    assert {:ok, %{review: review}} =
             Reviews.submit_verified(fixture.scope, %{
               place_id: fixture.ids.place,
               source_redemption_id: redemption.id,
               rating: 5,
               body: "Já avaliado pelo membro.",
               idempotency_key: "review-history-link"
             })

    token = authenticate!(fixture.ids.user)

    assert %{
             "data" => [
               %{
                 "review" => %{
                   "id" => review_id,
                   "status" => "pending",
                   "verification_kind" => "verified",
                   "source_redemption_id" => source_redemption_id,
                   "submitted_at" => submitted_at
                 }
               }
             ]
           } =
             conn
             |> put_req_header("authorization", "Bearer #{token}")
             |> get(~p"/api/v1/polos/#{fixture.polo_slug}/me/redemptions")
             |> json_response(200)

    assert review_id == review.id
    assert source_redemption_id == redemption.id
    assert {:ok, _submitted_at, 0} = DateTime.from_iso8601(submitted_at)
  end

  test "an authenticated member cannot list another member's redemptions", %{conn: conn} do
    visited = RedemptionsFixtures.create!()
    another_member = RedemptionsFixtures.create!()
    assert {:ok, _redemption} = Redemptions.confirm(visited.scope, visited.request)
    token = authenticate!(another_member.ids.user)

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> get(~p"/api/v1/polos/#{visited.polo_slug}/me/redemptions")
           |> json_response(200) == %{
             "data" => [],
             "meta" => %{
               "count" => 0,
               "page" => %{
                 "limit" => 20,
                 "has_more" => false,
                 "next_cursor" => nil
               }
             }
           }
  end

  test "redemption history stays isolated to the routed polo for the same member", %{conn: conn} do
    first = RedemptionsFixtures.create!()
    second = RedemptionsFixtures.create!(user_id: first.ids.user, insert_user: false)

    assert {:ok, first_redemption} = Redemptions.confirm(first.scope, first.request)
    assert {:ok, second_redemption} = Redemptions.confirm(second.scope, second.request)
    token = authenticate!(first.ids.user)

    response =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get(~p"/api/v1/polos/#{first.polo_slug}/me/redemptions")
      |> json_response(200)

    assert [%{"id" => redemption_id}] = response["data"]
    assert redemption_id == first_redemption.id
    refute inspect(response) =~ second_redemption.id
  end

  test "redemptions paginate newest first with an opaque cursor", %{conn: conn} do
    fixture = RedemptionsFixtures.create!(available_units: 2)
    assert {:ok, older_redemption} = Redemptions.confirm(fixture.scope, fixture.request)

    assert {:ok, newer_redemption} =
             Redemptions.confirm(fixture.scope, RedemptionsFixtures.request(fixture))

    token = authenticate!(fixture.ids.user)
    path = ~p"/api/v1/polos/#{fixture.polo_slug}/me/redemptions"

    first_page =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("#{path}?limit=1")
      |> json_response(200)

    assert %{
             "data" => [%{"id" => newer_redemption_id}],
             "meta" => %{
               "count" => 1,
               "page" => %{
                 "limit" => 1,
                 "has_more" => true,
                 "next_cursor" => cursor
               }
             }
           } = first_page

    assert newer_redemption_id == newer_redemption.id
    assert is_binary(cursor)
    refute cursor =~ newer_redemption.id

    second_page =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("#{path}?limit=1&after=#{cursor}")
      |> json_response(200)

    assert %{
             "data" => [%{"id" => older_redemption_id}],
             "meta" => %{
               "count" => 1,
               "page" => %{
                 "limit" => 1,
                 "has_more" => false,
                 "next_cursor" => nil
               }
             }
           } = second_page

    assert older_redemption_id == older_redemption.id
  end

  test "redemption history requires an authenticated bearer session", %{conn: conn} do
    assert conn
           |> get("/api/v1/polos/unknown-polo/me/redemptions")
           |> json_response(401) == %{"errors" => %{"detail" => "Unauthorized"}}
  end

  test "redemption history rejects invalid pagination", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    token = authenticate!(fixture.ids.user)
    path = ~p"/api/v1/polos/#{fixture.polo_slug}/me/redemptions"

    for query <- ["limit=0", "limit=101", "after=invalid"] do
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> get("#{path}?#{query}")
             |> json_response(400) == %{"errors" => %{"detail" => "Bad Request"}}
    end
  end

  test "redemption history returns not found for an unknown polo route", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    token = authenticate!(fixture.ids.user)

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> get("/api/v1/polos/unknown-polo/me/redemptions")
           |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session.token
  end

  defp suffix(polo_id), do: String.slice(String.replace(polo_id, "-", ""), -12, 12)
end
