defmodule ClubeiraWeb.Reviews.ReviewMediaControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Factory
  alias Clubeira.Redemptions
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.Reviews
  alias Clubeira.ReviewsFixtures

  @password "uma-senha-forte-para-midia-de-avaliacao"

  setup do
    previous = Application.get_env(:clubeira, :review_media_verifier)
    Application.put_env(:clubeira, :review_media_verifier, Clubeira.TestReviewMediaVerifier)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:clubeira, :review_media_verifier, previous),
        else: Application.delete_env(:clubeira, :review_media_verifier)
    end)

    :ok
  end

  test "a review author registers externally verified media and the public API resolves it", %{
    conn: conn
  } do
    fixture = pending_review!()
    token = authenticate!(fixture.ids.user)
    review = fixture.submission.review

    path =
      "/api/v1/polos/#{fixture.polo_slug}/places/#{fixture.ids.place}/reviews/#{review.id}/media"

    created =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("idempotency-key", "verified-review-media")
      |> post(path, %{"storage_key" => "reviews/verified/photo.webp", "position" => 0})

    assert %{
             "data" => %{
               "id" => media_id,
               "kind" => "image",
               "content_type" => "image/webp",
               "position" => 0,
               "width" => 1280,
               "height" => 720,
               "duration_ms" => nil,
               "status" => "ready"
             }
           } = json_response(created, 201)

    refute created.resp_body =~ "reviews/verified/photo.webp"
    refute created.resp_body =~ Base.url_encode64(:crypto.hash(:sha256, "verified review image"))

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{token}")
           |> put_req_header("idempotency-key", "verified-review-media")
           |> post(path, %{"storage_key" => "reviews/verified/photo.webp", "position" => 0})
           |> json_response(200) == json_response(created, 201)

    assert %{"errors" => %{"code" => "idempotency_conflict"}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> put_req_header("idempotency-key", "verified-review-media")
             |> post(path, %{"storage_key" => "reviews/verified/second.webp", "position" => 1})
             |> json_response(409)

    assert %{"errors" => %{"code" => "review_media_conflict"}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> put_req_header("idempotency-key", "conflicting-review-media-position")
             |> post(path, %{"storage_key" => "reviews/verified/second.webp", "position" => 0})
             |> json_response(409)

    assert %{"errors" => %{"code" => "media_not_verified"}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> put_req_header("idempotency-key", "unverified-review-media")
             |> post(path, %{"storage_key" => "reviews/unverified/photo.webp", "position" => 1})
             |> json_response(422)

    assert %{"errors" => %{"code" => "invalid_idempotency_key"}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{token}")
             |> post(path, %{"storage_key" => "reviews/verified/second.webp", "position" => 1})
             |> json_response(400)

    other_user = Factory.insert(:user)
    other_token = authenticate!(other_user.id)

    assert %{"errors" => %{"detail" => "Not Found"}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{other_token}")
             |> put_req_header("idempotency-key", "other-author-review-media")
             |> post(path, %{"storage_key" => "reviews/verified/second.webp", "position" => 1})
             |> json_response(404)

    moderator = ReviewsFixtures.grant_moderator!(fixture)

    assert {:ok, _published} =
             Reviews.moderate(moderator, %{
               review_id: review.id,
               action: "publish",
               reason: "Texto e mídia verificados.",
               idempotency_key: "publish-review-with-media"
             })

    assert %{
             "data" => [
               %{
                 "id" => review_id,
                 "media" => [
                   %{
                     "id" => ^media_id,
                     "kind" => "image",
                     "href" => href,
                     "status" => "ready"
                   }
                 ]
               }
             ]
           } =
             conn
             |> recycle()
             |> get("/api/v1/polos/#{fixture.polo_slug}/places/#{fixture.ids.place}/reviews")
             |> json_response(200)

    assert review_id == review.id

    delivery = conn |> recycle() |> get(href)
    assert delivery.status == 302

    assert get_resp_header(delivery, "location") == [
             "https://cdn.example.test/reviews/verified/photo.webp"
           ]

    assert %{"errors" => %{"detail" => "Not Found"}} =
             conn
             |> recycle()
             |> get("/api/v1/polos/#{fixture.polo_slug}/review-media/#{uuid7()}")
             |> json_response(404)

    assert {:ok, %{rows: [[1, 1, 1, 1]]}} =
             Repo.transact_in_polo(fixture.scope, fn repo ->
               result =
                 repo.query!(
                   """
                   SELECT
                     (SELECT count(*) FROM review_media WHERE id = $1),
                     (SELECT count(*) FROM domain_events
                      WHERE aggregate_type = 'review_media' AND aggregate_id = $1),
                     (SELECT count(*) FROM tenant_audit_events
                      WHERE resource_type = 'review_media' AND resource_id = $1),
                     (SELECT count(*) FROM outbox_messages AS message
                      JOIN domain_events AS event ON event.id = message.domain_event_id
                      WHERE event.aggregate_type = 'review_media' AND event.aggregate_id = $1)
                   """,
                   [Ecto.UUID.dump!(media_id)]
                 )

               {:ok, result}
             end)
  end

  defp pending_review! do
    fixture = RedemptionsFixtures.create!()
    assert {:ok, redemption} = Redemptions.confirm(fixture.scope, fixture.request)

    assert {:ok, submission} =
             Reviews.submit_verified(fixture.scope, %{
               place_id: fixture.ids.place,
               source_redemption_id: redemption.id,
               rating: 5,
               body: "Avaliação com foto verificada.",
               idempotency_key: "review-media-submission"
             })

    Map.merge(fixture, %{redemption: redemption, submission: submission})
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session.token
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
