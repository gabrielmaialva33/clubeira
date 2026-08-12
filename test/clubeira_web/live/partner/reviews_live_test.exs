defmodule ClubeiraWeb.Partner.ReviewsLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.Repo
  alias Clubeira.Reviews
  alias Clubeira.Reviews.ReviewResponse
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.PartnerBrowserFixtures

  test "lists assigned-place reviews and publishes a server-bound response", %{conn: conn} do
    fixture = PartnerBrowserFixtures.published_review!()
    partner = PartnerBrowserFixtures.grant_partner!(fixture)
    session = PartnerBrowserFixtures.authenticate!(partner.user)
    review_id = fixture.submission.review.id

    {:ok, view, html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/partner/reviews?polo=#{fixture.polo_slug}")

    refute html =~ session.token
    assert has_element?(view, "#partner-reviews-page")
    assert has_element?(view, "#partner-review-#{review_id}")
    assert has_element?(view, "#partner-nav-reviews[aria-current='page']")

    view
    |> element("#partner-respond-review-#{review_id}")
    |> render_click()

    assert has_element?(view, "#partner-response-editor")
    assert has_element?(view, "#partner-response-form")

    render_hook(view, "validate_response", %{"response" => "not-a-map"})
    assert has_element?(view, "#flash-error")

    render_hook(view, "save_response", %{
      "response" => %{
        "body" => "Obrigado pela visita! Esperamos receber você novamente.",
        "idempotency_key" => "browser-tampering"
      }
    })

    assert has_element?(
             view,
             "#partner-review-response-#{review_id}",
             "Obrigado pela visita! Esperamos receber você novamente."
           )

    refute has_element?(view, "#partner-response-editor")

    scope = Scope.new!(fixture.ids.polo, actor_user_id: partner.user.id)

    assert {:ok, %{response: %{revision_number: 1}}} =
             Reviews.get_partner_review(scope, review_id)

    view |> element("#partner-respond-review-#{review_id}") |> render_click()

    assert has_element?(
             view,
             "#response_body",
             "Obrigado pela visita! Esperamos receber você novamente."
           )

    view |> element("#partner-response-cancel") |> render_click()
    refute has_element?(view, "#partner-response-editor")
  end

  test "does not trust a tampered review identity from a browser event", %{conn: conn} do
    fixture = PartnerBrowserFixtures.published_review!()
    other_polo = PartnerBrowserFixtures.published_review!()
    partner = PartnerBrowserFixtures.grant_partner!(fixture)
    session = PartnerBrowserFixtures.authenticate!(partner.user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/partner/reviews?polo=#{fixture.polo_slug}")

    render_hook(view, "edit_response", %{"review_id" => other_polo.submission.review.id})

    assert has_element?(view, "#partner-reviews-page")
    assert has_element?(view, "#flash-error")
    refute has_element?(view, "#partner-response-editor")

    render_hook(view, "edit_response", %{"review_id" => "not-a-uuid"})
    assert has_element?(view, "#partner-reviews-page")
    assert has_element?(view, "#flash-error")
  end

  test "revalidates global affiliation before publishing a response", %{conn: conn} do
    fixture = PartnerBrowserFixtures.published_review!()
    partner = PartnerBrowserFixtures.grant_partner!(fixture)
    session = PartnerBrowserFixtures.authenticate!(partner.user)
    review_id = fixture.submission.review.id

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/partner/reviews?polo=#{fixture.polo_slug}")

    view
    |> element("#partner-respond-review-#{review_id}")
    |> render_click()

    PartnerBrowserFixtures.revoke_organization_membership!(partner.organization_membership)

    view
    |> form("#partner-response-form", response: %{body: "Esta resposta não pode persistir."})
    |> render_submit()

    assert_redirect(view, "/partner/login")

    scope = Scope.new!(fixture.ids.polo, actor_user_id: partner.user.id)
    assert {:error, :partner_access_required} = Reviews.list_partner_reviews(scope, %{})
  end

  test "canonicalizes invalid filters and survives malformed response events", %{conn: conn} do
    fixture = PartnerBrowserFixtures.published_review!()
    partner = PartnerBrowserFixtures.grant_partner!(fixture)
    session = PartnerBrowserFixtures.authenticate!(partner.user)
    authenticated_conn = init_test_session(conn, %{"backoffice_session_token" => session.token})
    expected_path = "/partner/reviews?polo=#{fixture.polo_slug}"

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(
               authenticated_conn,
               "/partner/reviews?polo=#{fixture.polo_slug}&after=malformed"
             )

    {:ok, view, _html} = live(authenticated_conn, expected_path)

    render_hook(view, "validate_response", %{"response" => %{"body" => "Sem seleção"}})
    render_hook(view, "save_response", %{"response" => "not-a-map"})
    render_hook(view, "filter", %{"filters" => "not-a-map"})
    render_hook(view, "edit_response", %{})
    render_hook(view, "change_polo", %{})

    assert has_element?(view, "#partner-reviews-page")
    assert has_element?(view, "#flash-error")
  end

  test "defaults the polo and canonicalizes unavailable polo and place filters", %{conn: conn} do
    fixture = PartnerBrowserFixtures.published_review!()
    partner = PartnerBrowserFixtures.grant_partner!(fixture)
    session = PartnerBrowserFixtures.authenticate!(partner.user)
    authenticated_conn = init_test_session(conn, %{"backoffice_session_token" => session.token})
    expected_path = "/partner/reviews?polo=#{fixture.polo_slug}"

    {:ok, view, _html} = live(authenticated_conn, "/partner/reviews")
    assert has_element?(view, "#partner-review-#{fixture.submission.review.id}")

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             authenticated_conn
             |> recycle()
             |> init_test_session(%{"backoffice_session_token" => session.token})
             |> live("/partner/reviews?polo=not-an-authorized-polo")

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             authenticated_conn
             |> recycle()
             |> init_test_session(%{"backoffice_session_token" => session.token})
             |> live(
               "/partner/reviews?polo=#{fixture.polo_slug}&place_id=#{Ecto.UUID.generate(version: 7)}"
             )
  end

  test "revalidates the persisted session before opening the response editor", %{conn: conn} do
    fixture = PartnerBrowserFixtures.published_review!()
    partner = PartnerBrowserFixtures.grant_partner!(fixture)
    session = PartnerBrowserFixtures.authenticate!(partner.user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/partner/reviews?polo=#{fixture.polo_slug}")

    assert {:ok, account_scope} = Accounts.fetch_scope_by_api_token(session.token)
    assert :ok = Accounts.revoke_session(account_scope)

    assert {:error, {:redirect, %{to: "/partner/login"}}} =
             view
             |> element("#partner-respond-review-#{fixture.submission.review.id}")
             |> render_click()
  end

  test "keeps polo and assigned-place filters in canonical URL state", %{conn: conn} do
    fixture = PartnerBrowserFixtures.published_review!()
    partner = PartnerBrowserFixtures.grant_partner!(fixture)
    session = PartnerBrowserFixtures.authenticate!(partner.user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/partner/reviews?polo=#{fixture.polo_slug}")

    view
    |> form("#partner-polo-form", context: %{polo: fixture.polo_slug})
    |> render_change()

    assert_patch(view, "/partner/reviews?polo=#{fixture.polo_slug}")

    view
    |> form("#partner-review-filters", filters: %{place_id: fixture.ids.place})
    |> render_change()

    patched = assert_patch(view)
    query = patched |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert query["polo"] == fixture.polo_slug
    assert query["place_id"] == fixture.ids.place
    assert has_element?(view, "#partner-review-#{fixture.submission.review.id}")
  end

  test "validates the response and refuses a review hidden after the editor opened", %{conn: conn} do
    fixture = PartnerBrowserFixtures.published_review!()
    partner = PartnerBrowserFixtures.grant_partner!(fixture)
    session = PartnerBrowserFixtures.authenticate!(partner.user)
    review_id = fixture.submission.review.id

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/partner/reviews?polo=#{fixture.polo_slug}")

    view |> element("#partner-respond-review-#{review_id}") |> render_click()

    view
    |> form("#partner-response-form", response: %{body: ""})
    |> render_change()

    assert has_element?(view, "#response_body.border-red-500")

    view
    |> form("#partner-response-form", response: %{body: ""})
    |> render_submit()

    assert has_element?(view, "#response_body.border-red-500")
    assert has_element?(view, "#partner-response-editor")

    partner_scope = Scope.new!(fixture.ids.polo, actor_user_id: partner.user.id)

    assert {:ok, report} =
             Reviews.report(partner_scope, %{
               place_id: fixture.ids.place,
               review_id: review_id,
               reason_code: "spam",
               idempotency_key: "report-during-partner-response-#{Ecto.UUID.generate(version: 7)}"
             })

    assert {:ok, _hidden} =
             Reviews.resolve_report(partner.admin, %{
               review_report_id: report["id"],
               action: "hide",
               reason: "Conteúdo ocultado durante a resposta do parceiro.",
               idempotency_key: "hide-during-partner-response-#{Ecto.UUID.generate(version: 7)}"
             })

    view
    |> form("#partner-response-form", response: %{body: "Resposta que não deve persistir."})
    |> render_submit()

    assert has_element?(view, "#flash-error")
    refute has_element?(view, "#partner-response-editor")

    refute Repo.exists?(from response in ReviewResponse, where: response.review_id == ^review_id)
  end
end
