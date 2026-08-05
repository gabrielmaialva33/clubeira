defmodule ClubeiraWeb.ReviewControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Redemptions
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo

  @password "uma-senha-de-review-forte"

  test "an authenticated member submits a verified review for a redeemed place", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    assert {:ok, redemption} = Redemptions.confirm(fixture.scope, fixture.request)
    token = authenticate!(fixture.ids.user)

    response =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("idempotency-key", "review-api-001")
      |> post(~p"/api/v1/polos/#{fixture.polo_slug}/places/#{fixture.ids.place}/reviews", %{
        "rating" => 5,
        "title" => "Atendimento excelente",
        "body" => "O benefício foi entregue exatamente como anunciado.",
        "source_redemption_id" => redemption.id
      })
      |> json_response(201)

    assert %{
             "data" => %{
               "id" => review_id,
               "place_id" => place_id,
               "source_redemption_id" => source_redemption_id,
               "verification_kind" => "verified",
               "status" => "pending",
               "revision_number" => 1,
               "rating" => 5,
               "title" => "Atendimento excelente",
               "body" => "O benefício foi entregue exatamente como anunciado.",
               "submitted_at" => submitted_at
             }
           } = response

    assert {:ok, ^review_id} = Ecto.UUID.cast(review_id)
    assert place_id == fixture.ids.place
    assert source_redemption_id == redemption.id
    assert {:ok, _submitted_at, 0} = DateTime.from_iso8601(submitted_at)
  end

  test "replaying the same review submission returns the original review", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    assert {:ok, redemption} = Redemptions.confirm(fixture.scope, fixture.request)
    token = authenticate!(fixture.ids.user)
    idempotency_key = "review-api-replay"

    request = %{
      "rating" => 4,
      "body" => "Voltaria ao estabelecimento.",
      "source_redemption_id" => redemption.id
    }

    first =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("idempotency-key", idempotency_key)
      |> post(
        ~p"/api/v1/polos/#{fixture.polo_slug}/places/#{fixture.ids.place}/reviews",
        request
      )
      |> json_response(201)

    replayed =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("idempotency-key", idempotency_key)
      |> post(
        ~p"/api/v1/polos/#{fixture.polo_slug}/places/#{fixture.ids.place}/reviews",
        request
      )
      |> json_response(201)

    assert replayed == first
  end

  test "reusing a review idempotency key with different content returns conflict", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    assert {:ok, redemption} = Redemptions.confirm(fixture.scope, fixture.request)
    token = authenticate!(fixture.ids.user)
    idempotency_key = "review-api-conflict"

    request = %{
      "rating" => 5,
      "body" => "Experiência muito boa.",
      "source_redemption_id" => redemption.id
    }

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", idempotency_key)
           |> post(
             ~p"/api/v1/polos/#{fixture.polo_slug}/places/#{fixture.ids.place}/reviews",
             request
           )
           |> json_response(201)

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", idempotency_key)
           |> post(
             ~p"/api/v1/polos/#{fixture.polo_slug}/places/#{fixture.ids.place}/reviews",
             Map.put(request, "rating", 1)
           )
           |> json_response(409) == %{"errors" => %{"detail" => "Conflict"}}
  end

  test "an authenticated member cannot review with another member's redemption", %{conn: conn} do
    visited_place = RedemptionsFixtures.create!()
    another_member = RedemptionsFixtures.create!()
    assert {:ok, redemption} = Redemptions.confirm(visited_place.scope, visited_place.request)
    token = authenticate!(another_member.ids.user)

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", "review-api-other-member")
           |> post(
             ~p"/api/v1/polos/#{visited_place.polo_slug}/places/#{visited_place.ids.place}/reviews",
             %{
               "rating" => 5,
               "body" => "Não deveria ser aceita.",
               "source_redemption_id" => redemption.id
             }
           )
           |> json_response(422) == %{
             "errors" => %{"detail" => "Unprocessable Content"}
           }
  end

  test "a redemption from another polo cannot authorize a review", %{conn: conn} do
    first_polo = RedemptionsFixtures.create!()

    second_polo =
      RedemptionsFixtures.create!(user_id: first_polo.ids.user, insert_user: false)

    assert {:ok, redemption} = Redemptions.confirm(first_polo.scope, first_polo.request)
    token = authenticate!(first_polo.ids.user)

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", "review-api-other-polo")
           |> post(
             ~p"/api/v1/polos/#{second_polo.polo_slug}/places/#{second_polo.ids.place}/reviews",
             %{
               "rating" => 5,
               "body" => "O resgate pertence a outro polo.",
               "source_redemption_id" => redemption.id
             }
           )
           |> json_response(422) == %{
             "errors" => %{"detail" => "Unprocessable Content"}
           }
  end

  test "a polo can disable new review submissions through its current policy", %{conn: conn} do
    fixture = RedemptionsFixtures.create!(review_policy: "disabled")
    assert {:ok, redemption} = Redemptions.confirm(fixture.scope, fixture.request)
    token = authenticate!(fixture.ids.user)

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", "review-api-disabled")
           |> post(
             ~p"/api/v1/polos/#{fixture.polo_slug}/places/#{fixture.ids.place}/reviews",
             %{
               "rating" => 5,
               "body" => "A policy deve impedir esta avaliação.",
               "source_redemption_id" => redemption.id
             }
           )
           |> json_response(422) == %{
             "errors" => %{"detail" => "Unprocessable Content"}
           }
  end

  test "a null optional title is accepted as absent", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    assert {:ok, redemption} = Redemptions.confirm(fixture.scope, fixture.request)
    token = authenticate!(fixture.ids.user)

    assert %{"data" => %{"title" => nil}} =
             conn
             |> put_req_header("authorization", "Bearer #{token}")
             |> put_req_header("idempotency-key", "review-api-null-title")
             |> post(
               ~p"/api/v1/polos/#{fixture.polo_slug}/places/#{fixture.ids.place}/reviews",
               %{
                 "rating" => 4,
                 "title" => nil,
                 "body" => "Título não é obrigatório.",
                 "source_redemption_id" => redemption.id
               }
             )
             |> json_response(201)
  end

  test "invalid review content does not consume the idempotency key", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    assert {:ok, redemption} = Redemptions.confirm(fixture.scope, fixture.request)
    token = authenticate!(fixture.ids.user)
    idempotency_key = "review-api-validation"
    path = ~p"/api/v1/polos/#{fixture.polo_slug}/places/#{fixture.ids.place}/reviews"

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", idempotency_key)
           |> post(path, %{
             "rating" => 6,
             "body" => "   ",
             "source_redemption_id" => redemption.id
           })
           |> json_response(422) == %{
             "errors" => %{"detail" => "Unprocessable Content"}
           }

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", idempotency_key)
           |> post(path, %{
             "rating" => 5,
             "body" => "Agora o conteúdo é válido.",
             "source_redemption_id" => redemption.id
           })
           |> json_response(201)
  end

  test "review submission requires an authenticated bearer session", %{conn: conn} do
    assert conn
           |> put_req_header("idempotency-key", "review-api-unauthenticated")
           |> post(
             ~p"/api/v1/polos/unknown-polo/places/#{Ecto.UUID.generate()}/reviews",
             %{}
           )
           |> json_response(401) == %{"errors" => %{"detail" => "Unauthorized"}}
  end

  test "review submission requires exactly one idempotency key header", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    token = authenticate!(fixture.ids.user)

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> post(
             ~p"/api/v1/polos/#{fixture.polo_slug}/places/#{fixture.ids.place}/reviews",
             %{}
           )
           |> json_response(422) == %{
             "errors" => %{"detail" => "Unprocessable Content"}
           }
  end

  test "a member cannot create a second review for the same place", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    assert {:ok, redemption} = Redemptions.confirm(fixture.scope, fixture.request)
    token = authenticate!(fixture.ids.user)
    path = ~p"/api/v1/polos/#{fixture.polo_slug}/places/#{fixture.ids.place}/reviews"

    request = %{
      "rating" => 5,
      "body" => "Primeira avaliação.",
      "source_redemption_id" => redemption.id
    }

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", "review-api-first")
           |> post(path, request)
           |> json_response(201)

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", "review-api-second")
           |> post(path, Map.put(request, "body", "Segunda avaliação."))
           |> json_response(422) == %{
             "errors" => %{"detail" => "Unprocessable Content"}
           }
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session.token
  end
end
