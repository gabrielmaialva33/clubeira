defmodule ClubeiraWeb.Backoffice.ModerationReviewsLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Repo
  alias Clubeira.Reviews
  alias Clubeira.ReviewsFixtures

  @password "uma-senha-forte-para-a-moderacao-web"

  test "lists only pending reviews from the selected polo for a moderator", %{conn: conn} do
    fixture = ReviewsFixtures.pending_review!()
    other_polo = ReviewsFixtures.pending_review!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)
    session = authenticate!(moderator_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/moderation/reviews?polo=#{fixture.polo_slug}")

    assert has_element?(view, "#moderation-reviews-page")

    assert has_element?(
             view,
             "#moderation-reviews #review-#{fixture.submission.review.id}"
           )

    refute has_element?(
             view,
             "#moderation-reviews #review-#{other_polo.submission.review.id}"
           )

    assert has_element?(view, "#backoffice-nav-moderation[aria-current='page']")
  end

  test "publishes a pending review and removes it from the queue", %{conn: conn} do
    fixture = ReviewsFixtures.pending_review!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)
    review_id = fixture.submission.review.id
    session = authenticate!(moderator_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/moderation/reviews?polo=#{fixture.polo_slug}")

    view
    |> form("#review-moderation-form-#{review_id}",
      moderation: %{
        action: "publish",
        reason: "Conteúdo verificado e adequado às diretrizes."
      }
    )
    |> render_submit()

    refute has_element?(view, "#review-#{review_id}")
    assert has_element?(view, "#flash-info")

    assert {:ok, %{reviews: [%{id: ^review_id, status: "published"}]}} =
             Reviews.list_for_moderation(moderator_scope, %{"status" => "published"})
  end

  test "rejects a moderation event for a review outside the rendered page", %{conn: conn} do
    fixture = ReviewsFixtures.pending_review!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)
    assert {:ok, %{reviews: [review]}} = Reviews.list_for_moderation(moderator_scope, %{})
    session = authenticate!(moderator_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(
        "/admin/moderation/reviews?polo=#{fixture.polo_slug}&after=#{cursor(review.submitted_at, review.id)}"
      )

    refute has_element?(view, "#review-#{review.id}")

    render_hook(view, "moderate_review", %{
      "review_id" => review.id,
      "moderation" => %{
        "action" => "publish",
        "reason" => "Evento forjado fora da página renderizada.",
        "idempotency_key" => "forged-review-moderation"
      }
    })

    assert has_element?(view, "#flash-error")

    assert {:ok, %{reviews: [%{id: review_id, status: "pending"}]}} =
             Reviews.list_for_moderation(moderator_scope, %{})

    assert review_id == review.id
  end

  test "keeps a pending review unchanged when the moderation form is invalid", %{conn: conn} do
    fixture = ReviewsFixtures.pending_review!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)
    review_id = fixture.submission.review.id
    session = authenticate!(moderator_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/moderation/reviews?polo=#{fixture.polo_slug}")

    view
    |> form("#review-moderation-form-#{review_id}",
      moderation: %{action: "", reason: ""}
    )
    |> render_submit()

    assert has_element?(view, "#review-moderation-form-#{review_id}")
    assert has_element?(view, "#flash-error")

    assert {:ok, %{reviews: [%{id: ^review_id, status: "pending"}]}} =
             Reviews.list_for_moderation(moderator_scope, %{})
  end

  test "refetches a review that another moderator already decided", %{conn: conn} do
    fixture = ReviewsFixtures.pending_review!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)
    review_id = fixture.submission.review.id
    session = authenticate!(moderator_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/moderation/reviews?polo=#{fixture.polo_slug}")

    assert {:ok, _moderation} =
             Reviews.moderate(moderator_scope, %{
               review_id: review_id,
               action: "publish",
               reason: "Decisão concorrente válida.",
               idempotency_key: "concurrent-review-moderation-#{Ecto.UUID.generate()}"
             })

    view
    |> form("#review-moderation-form-#{review_id}",
      moderation: %{action: "reject", reason: "Decisão web já obsoleta."}
    )
    |> render_submit()

    assert has_element?(view, "#flash-error")
    refute has_element?(view, "#review-#{review_id}")
  end

  test "a revoked browser session cannot moderate a review", %{conn: conn} do
    fixture = ReviewsFixtures.pending_review!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)
    review_id = fixture.submission.review.id
    session = authenticate!(moderator_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/moderation/reviews?polo=#{fixture.polo_slug}")

    assert {:ok, account_scope} = Accounts.fetch_scope_by_api_token(session.token)
    assert :ok = Accounts.revoke_session(account_scope)

    view
    |> form("#review-moderation-form-#{review_id}",
      moderation: %{
        action: "publish",
        reason: "A sessão revogada não pode decidir uma avaliação."
      }
    )
    |> render_submit()

    assert_redirect(view, "/admin/login")

    assert {:ok, %{reviews: [%{id: ^review_id, status: "pending"}]}} =
             Reviews.list_for_moderation(moderator_scope, %{})
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session
  end

  defp cursor(recorded_at, id) do
    <<DateTime.to_unix(recorded_at, :microsecond)::signed-64, Ecto.UUID.dump!(id)::binary>>
    |> Base.url_encode64(padding: false)
  end
end
