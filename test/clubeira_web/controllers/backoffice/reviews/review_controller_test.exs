defmodule ClubeiraWeb.Backoffice.ReviewControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  @password "uma-senha-de-moderacao-forte"

  test "moderation queue pagination rejects malformed parameters as a bad request", %{conn: conn} do
    fixture = ReviewsFixtures.pending_review!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)
    token = authenticate!(moderator_scope.actor_user_id)

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> get("/api/v1/polos/#{fixture.polo_slug}/backoffice/reviews?limit=0")
           |> json_response(400) == %{"errors" => %{"detail" => "Bad Request"}}
  end

  test "a polo moderator lists the pending queue with its immutable content", %{conn: conn} do
    fixture = ReviewsFixtures.pending_review!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)
    token = authenticate!(moderator_scope.actor_user_id)

    assert %{
             "data" => [
               %{
                 "id" => review_id,
                 "place_id" => place_id,
                 "author_user_id" => author_user_id,
                 "source_redemption_id" => redemption_id,
                 "status" => "pending",
                 "verification_kind" => "verified",
                 "revision_number" => 1,
                 "rating" => 5,
                 "title" => "Experiência verificada",
                 "body" => "O benefício foi entregue como anunciado.",
                 "submitted_at" => submitted_at
               }
             ],
             "page" => %{"limit" => 20, "has_more" => false, "next_cursor" => nil}
           } =
             conn
             |> put_req_header("authorization", "Bearer #{token}")
             |> get("/api/v1/polos/#{fixture.polo_slug}/backoffice/reviews")
             |> json_response(200)

    assert review_id == fixture.submission.review.id
    assert place_id == fixture.ids.place
    assert author_user_id == fixture.ids.user
    assert redemption_id == fixture.redemption.id
    assert {:ok, _submitted_at, 0} = DateTime.from_iso8601(submitted_at)
  end

  test "membership without a moderation role is forbidden from the queue", %{conn: conn} do
    fixture = ReviewsFixtures.pending_review!()
    token = authenticate!(fixture.ids.user)

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> get("/api/v1/polos/#{fixture.polo_slug}/backoffice/reviews")
           |> json_response(403) == %{"errors" => %{"detail" => "Forbidden"}}
  end

  test "publishing closes the moderation command and exposes the review publicly", %{conn: conn} do
    fixture = ReviewsFixtures.pending_review!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)
    token = authenticate!(moderator_scope.actor_user_id)
    public_path = "/api/v1/polos/#{fixture.polo_slug}/places/#{fixture.ids.place}/reviews"

    assert conn |> get(public_path) |> json_response(200) == %{
             "data" => [],
             "page" => %{"limit" => 20, "has_more" => false, "next_cursor" => nil}
           }

    moderation_path =
      "/api/v1/polos/#{fixture.polo_slug}/backoffice/reviews/#{fixture.submission.review.id}/moderation-actions"

    request = %{
      "action" => "publish",
      "reason" => "Avaliação verificada e adequada para publicação."
    }

    first =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("idempotency-key", "review-moderation-api-001")
      |> post(moderation_path, request)
      |> json_response(201)

    assert %{
             "data" => %{
               "id" => action_id,
               "review_id" => review_id,
               "action" => "publish",
               "status" => "published",
               "moderated_at" => moderated_at
             }
           } = first

    assert review_id == fixture.submission.review.id
    assert {:ok, ^action_id} = Ecto.UUID.cast(action_id)
    assert {:ok, _moderated_at, 0} = DateTime.from_iso8601(moderated_at)

    replayed =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("idempotency-key", "review-moderation-api-001")
      |> post(moderation_path, request)
      |> json_response(201)

    assert replayed == first

    assert %{
             "data" => [
               %{
                 "id" => ^review_id,
                 "place_id" => place_id,
                 "verification_kind" => "verified",
                 "rating" => 5,
                 "title" => "Experiência verificada",
                 "body" => "O benefício foi entregue como anunciado.",
                 "published_at" => published_at
               }
             ]
           } =
             conn
             |> recycle()
             |> get(public_path)
             |> json_response(200)

    assert place_id == fixture.ids.place
    assert {:ok, _published_at, 0} = DateTime.from_iso8601(published_at)
  end

  test "a rejected review never enters the public feed", %{conn: conn} do
    fixture = ReviewsFixtures.pending_review!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)
    token = authenticate!(moderator_scope.actor_user_id)

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", "review-moderation-api-reject")
           |> post(
             "/api/v1/polos/#{fixture.polo_slug}/backoffice/reviews/#{fixture.submission.review.id}/moderation-actions",
             %{
               "action" => "reject",
               "reason" => "Conteúdo incompatível com as diretrizes."
             }
           )
           |> json_response(201)

    assert conn
           |> recycle()
           |> get("/api/v1/polos/#{fixture.polo_slug}/places/#{fixture.ids.place}/reviews")
           |> json_response(200) == %{
             "data" => [],
             "page" => %{"limit" => 20, "has_more" => false, "next_cursor" => nil}
           }
  end

  test "a moderator cannot act on a review originating in another polo", %{conn: conn} do
    review_fixture = ReviewsFixtures.pending_review!()
    other_polo = ReviewsFixtures.pending_review!()
    moderator_scope = ReviewsFixtures.grant_moderator!(other_polo)
    token = authenticate!(moderator_scope.actor_user_id)

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", "review-moderation-cross-polo")
           |> post(
             "/api/v1/polos/#{other_polo.polo_slug}/backoffice/reviews/#{review_fixture.submission.review.id}/moderation-actions",
             %{"action" => "publish", "reason" => "Não pertence a este polo."}
           )
           |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}
  end

  test "moderation rejects malformed commands without consuming a transition", %{conn: conn} do
    fixture = ReviewsFixtures.pending_review!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)
    token = authenticate!(moderator_scope.actor_user_id)

    assert conn
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", "review-moderation-invalid")
           |> post(
             "/api/v1/polos/#{fixture.polo_slug}/backoffice/reviews/#{fixture.submission.review.id}/moderation-actions",
             %{"action" => "remove", "reason" => "x"}
           )
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
