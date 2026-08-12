defmodule ClubeiraWeb.Member.PlaceReviewsLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.Devices.UserDeviceAuthorization
  alias Clubeira.Factory
  alias Clubeira.People.Person
  alias Clubeira.People.UserPersonLink
  alias Clubeira.Repo
  alias Clubeira.Reviews
  alias Clubeira.Reviews.Review
  alias Clubeira.Reviews.ReviewRevision
  alias Clubeira.ReviewsFixtures
  alias Clubeira.Tenancy.ActorScope
  alias ClubeiraWeb.PublicReviewKey

  @password "uma-senha-forte-para-denunciar-no-app"

  test "resolves the opaque target from the public review link", %{conn: conn} do
    {fixture, _moderator_scope} = published_review!()
    reporter = Factory.insert(:user)
    session = authenticate!(reporter)
    review_key = PublicReviewKey.from_id(fixture.submission.review.id)
    review_token = PublicReviewKey.sign(fixture.submission.review.id)

    {:ok, view, html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("#{place_reviews_path(fixture)}?report=#{review_token}")

    assert has_element?(view, "#member-review-#{review_key}")
    assert has_element?(view, "#member-review-report-form")
    refute html =~ fixture.submission.review.id
    refute html =~ fixture.ids.place
  end

  test "resolves an opaque target outside the first keyset page without scanning", %{conn: conn} do
    {fixture, _moderator_scope} = published_review!()
    insert_newer_published_reviews!(fixture, 20)

    reporter = Factory.insert(:user)
    session = authenticate!(reporter)
    review_key = PublicReviewKey.from_id(fixture.submission.review.id)
    review_token = PublicReviewKey.sign(fixture.submission.review.id)

    {:ok, view, html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("#{place_reviews_path(fixture)}?report=#{review_token}&limit=5")

    assert has_element?(view, "#member-review-#{review_key}")
    assert has_element?(view, "#member-review-report-form")
    assert has_element?(view, "#member-place-reviews-next-page")
    refute html =~ fixture.submission.review.id
    refute html =~ fixture.ids.place

    view
    |> element("#member-place-reviews-next-page")
    |> render_click()

    assert_patch(view)
    refute has_element?(view, "#member-review-report-form")
  end

  test "reports a published review with its identities bound by the server", %{conn: conn} do
    {fixture, moderator_scope} = published_review!()
    reporter = Factory.insert(:user)
    session = authenticate!(reporter)
    review_key = PublicReviewKey.from_id(fixture.submission.review.id)

    {:ok, view, html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(place_reviews_path(fixture))

    assert has_element?(view, "#member-place-reviews")
    assert has_element?(view, "#member-review-#{review_key}")
    refute html =~ fixture.submission.review.id
    refute html =~ fixture.ids.place

    view
    |> element("#report-review-#{review_key}")
    |> render_click()

    assert has_element?(view, "#member-review-report-form")
    refute has_element?(view, "#member-review-report-form [name$='[place_id]']")
    refute has_element?(view, "#member-review-report-form [name$='[review_id]']")
    refute has_element?(view, "#member-review-report-form [name$='[idempotency_key]']")

    view
    |> form("#member-review-report-form",
      review_report_request: %{
        reason_code: "personal_data",
        details: "A avaliação expõe um telefone pessoal."
      }
    )
    |> render_submit()

    assert has_element?(view, "#review-report-submitted-#{review_key}")
    refute has_element?(view, "#member-review-report-form")

    assert {:ok, %{reports: [report]}} = Reviews.list_reports(moderator_scope, %{})
    assert report.review_id == fixture.submission.review.id
    assert report.reporter_user_id == reporter.id
    assert report.reason_code == "personal_data"

    render_hook(view, "report_review", %{"review-key" => review_key})

    view
    |> form("#member-review-report-form",
      review_report_request: %{reason_code: "spam"}
    )
    |> render_submit()

    assert has_element?(view, "#review-report-submitted-#{review_key}")
    assert has_element?(view, "#flash-info")
    assert {:ok, %{reports: [_single_report]}} = Reviews.list_reports(moderator_scope, %{})
  end

  test "revalidates the browser session before writing a report", %{conn: conn} do
    {fixture, moderator_scope} = published_review!()
    reporter = Factory.insert(:user)
    session = authenticate!(reporter)
    review_key = PublicReviewKey.from_id(fixture.submission.review.id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(place_reviews_path(fixture))

    view |> element("#report-review-#{review_key}") |> render_click()

    assert {:ok, account_scope} = Accounts.fetch_scope_by_api_token(session.token)
    assert :ok = Accounts.revoke_session(account_scope)

    assert {:error, {:redirect, %{to: "/app/login"}}} =
             view
             |> form("#member-review-report-form",
               review_report_request: %{reason_code: "spam"}
             )
             |> render_submit()

    assert {:ok, %{reports: []}} = Reviews.list_reports(moderator_scope, %{})
  end

  test "does not allow the author to report their own review", %{conn: conn} do
    {fixture, moderator_scope} = published_review!()
    author = Clubeira.Repo.get!(Clubeira.Accounts.User, fixture.ids.user)
    session = authenticate!(author)
    review_key = PublicReviewKey.from_id(fixture.submission.review.id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(place_reviews_path(fixture))

    view |> element("#report-review-#{review_key}") |> render_click()

    view
    |> form("#member-review-report-form",
      review_report_request: %{reason_code: "spam"}
    )
    |> render_submit()

    assert has_element?(view, "#flash-error")
    refute has_element?(view, "#member-review-report-form")
    assert {:ok, %{reports: []}} = Reviews.list_reports(moderator_scope, %{})
  end

  test "does not bind a tampered or cross-polo review token", %{conn: conn} do
    {fixture, moderator_scope} = published_review!()
    {other, other_moderator_scope} = published_review!()
    reporter = Factory.insert(:user)
    session = authenticate!(reporter)
    cross_polo_token = PublicReviewKey.sign(other.submission.review.id)

    {:ok, view, html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("#{place_reviews_path(fixture)}?report=#{cross_polo_token}")

    refute has_element?(view, "#member-review-report-form")
    assert has_element?(view, "#flash-error")
    refute html =~ other.submission.review.id

    render_hook(view, "report_review", %{"review-key" => cross_polo_token})

    refute has_element?(view, "#member-review-report-form")
    assert {:ok, %{reports: []}} = Reviews.list_reports(moderator_scope, %{})
    assert {:ok, %{reports: []}} = Reviews.list_reports(other_moderator_scope, %{})

    valid_token = PublicReviewKey.sign(fixture.submission.review.id)
    tampered_token = flip_last_character(valid_token)

    {:ok, tampered_view, tampered_html} =
      conn
      |> recycle()
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("#{place_reviews_path(fixture)}?report=#{tampered_token}")

    refute has_element?(tampered_view, "#member-review-report-form")
    assert has_element?(tampered_view, "#flash-error")
    refute tampered_html =~ fixture.submission.review.id
  end

  test "rejects malformed and invalid report payloads without crashing", %{conn: conn} do
    {fixture, moderator_scope} = published_review!()
    reporter = Factory.insert(:user)
    session = authenticate!(reporter)
    review_key = PublicReviewKey.from_id(fixture.submission.review.id)

    authenticated_conn =
      init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: expected_path}}} =
             live(authenticated_conn, "#{place_reviews_path(fixture)}?after=malformed")

    assert expected_path == place_reviews_path(fixture)

    {:ok, view, _html} =
      live(authenticated_conn, place_reviews_path(fixture))

    render_hook(view, "report_review", %{})
    assert has_element?(view, "#flash-error")

    view |> element("#report-review-#{review_key}") |> render_click()

    render_hook(view, "validate_report", %{})
    render_hook(view, "validate_report", %{"review_report_request" => "not-a-map"})

    view
    |> form("#member-review-report-form",
      review_report_request: %{reason_code: "other", details: ""}
    )
    |> render_change()

    assert has_element?(view, "#review_report_request_details.border-red-500")

    view
    |> element("#cancel-member-review-report")
    |> render_click()

    refute has_element?(view, "#member-review-report-form")

    render_hook(view, "submit_report", %{
      "review_report_request" => %{"reason_code" => "spam"}
    })

    assert has_element?(view, "#flash-error")

    view |> element("#report-review-#{review_key}") |> render_click()

    render_hook(view, "submit_report", %{"review_report_request" => "not-a-map"})

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#member-review-report-form")

    view
    |> form("#member-review-report-form",
      review_report_request: %{reason_code: "other", details: ""}
    )
    |> render_submit()

    assert has_element?(view, "#review_report_request_details.border-red-500")
    assert {:ok, %{reports: []}} = Reviews.list_reports(moderator_scope, %{})
  end

  defp published_review! do
    fixture = ReviewsFixtures.pending_review!(available_units: 21)
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)

    assert {:ok, _result} =
             Reviews.moderate(moderator_scope, %{
               review_id: fixture.submission.review.id,
               action: "publish",
               reason: "Conteúdo adequado para publicação.",
               idempotency_key: "publish-before-member-report-#{uuid7()}"
             })

    {fixture, moderator_scope}
  end

  defp authenticate!(user) do
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session
  end

  defp insert_newer_published_reviews!(fixture, count) do
    now = DateTime.utc_now(:microsecond)

    rows =
      Enum.map(1..count, fn sequence ->
        user = Factory.insert(:user)

        grant_contract_access!(fixture, user.id, sequence, now)

        scope = %{
          fixture.scope
          | actor_user_id: user.id,
            request_id: uuid7()
        }

        request = %{
          fixture.request
          | idempotency_key: "review-page-redeem-#{sequence}-#{uuid7()}",
            request_nonce: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
        }

        assert {:ok, redemption} = Clubeira.Redemptions.confirm(scope, request)

        %{
          sequence: sequence,
          user_id: user.id,
          redemption_id: redemption.id,
          review_id: uuid7(),
          revision_id: uuid7(),
          recorded_at: DateTime.add(now, sequence, :second)
        }
      end)

    assert {:ok, {^count, ^count}} =
             Repo.transact_in_polo(fixture.scope, fn repo ->
               {review_count, nil} =
                 repo.insert_all(
                   Review,
                   Enum.map(rows, fn row ->
                     %{
                       id: row.review_id,
                       place_id: fixture.ids.place,
                       author_user_id: row.user_id,
                       source_redemption_id: row.redemption_id,
                       verification_kind: "verified",
                       status: "published",
                       published_at: row.recorded_at,
                       inserted_at: now,
                       updated_at: now
                     }
                   end)
                 )

               {revision_count, nil} =
                 repo.insert_all(
                   ReviewRevision,
                   Enum.map(rows, fn row ->
                     %{
                       id: row.revision_id,
                       review_id: row.review_id,
                       author_user_id: row.user_id,
                       revision_number: 1,
                       rating: 5,
                       title: "Review paginado #{row.sequence}",
                       body: "Conteúdo publicado para provar a busca por keyset.",
                       inserted_at: now
                     }
                   end)
                 )

               {:ok, {review_count, revision_count}}
             end)
  end

  defp grant_contract_access!(fixture, user_id, sequence, now) do
    person_id = uuid7()
    beneficiary_id = uuid7()

    actor_scope = ActorScope.new!(user_id, uuid7())

    assert {:ok, {1, 1, 1}} =
             Repo.transact_as_actor(actor_scope, fn repo ->
               {person_count, nil} =
                 repo.insert_all(Person, [
                   %{
                     id: person_id,
                     display_name: "Leitor paginado #{sequence}",
                     status: "active",
                     inserted_at: now,
                     updated_at: now
                   }
                 ])

               {link_count, nil} =
                 repo.insert_all(UserPersonLink, [
                   %{
                     user_id: user_id,
                     person_id: person_id,
                     relationship: "self",
                     status: "active",
                     inserted_at: now,
                     updated_at: now
                   }
                 ])

               {device_count, nil} =
                 repo.insert_all(UserDeviceAuthorization, [
                   %{
                     user_id: user_id,
                     device_installation_id: fixture.ids.device,
                     status: "active",
                     authorized_at: now,
                     inserted_at: now
                   }
                 ])

               {:ok, {person_count, link_count, device_count}}
             end)

    assert {:ok, 1} =
             Repo.transact_in_polo(fixture.scope, fn repo ->
               {inserted, nil} =
                 repo.insert_all("contract_beneficiaries", [
                   %{
                     id: Ecto.UUID.dump!(beneficiary_id),
                     polo_id: Ecto.UUID.dump!(fixture.ids.polo),
                     access_contract_id: Ecto.UUID.dump!(fixture.ids.access_contract),
                     person_id: Ecto.UUID.dump!(person_id),
                     relationship: "guest",
                     valid_during: Factory.tstz_range(DateTime.add(now, -3600)),
                     status: "active",
                     inserted_at: now,
                     updated_at: now
                   }
                 ])

               {:ok, inserted}
             end)
  end

  defp place_reviews_path(fixture) do
    place_slug = "place-#{short_suffix(fixture.ids.polo)}"
    "/app/catalog/#{fixture.polo_slug}/places/#{place_slug}/reviews"
  end

  defp short_suffix(uuid), do: uuid |> String.replace("-", "") |> String.slice(-12, 12)
  defp flip_last_character(value), do: String.replace_suffix(value, String.last(value), "!")
  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
