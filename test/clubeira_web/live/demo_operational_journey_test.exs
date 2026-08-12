defmodule ClubeiraWeb.DemoOperationalJourneyTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.Privacy.Request
  alias Clubeira.Repo
  alias Clubeira.Seeds
  alias Clubeira.Seeds.Demo.Ids

  test "the canonical seed opens every operational web workspace", %{conn: conn} do
    summary = Clubeira.TestDatabaseRole.as_owner(&Seeds.run!/0)

    member_token = login!(summary.member_email, "clubeira-demo-local")
    admin_token = login!(summary.admin_email, "clubeira-admin-local")
    partner_token = login!(summary.partner_email, "clubeira-parceiro-local")

    privacy_request_id =
      Clubeira.TestDatabaseRole.as_owner(fn ->
        Repo.get_by!(Request, client_request_id: Ids.fetch!(:demo_privacy_request)).id
      end)

    assert_public_pages(conn)
    assert_member_pages(member_token)
    assert_backoffice_pages(admin_token)
    assert_partner_pages(partner_token)
    assert_platform_pages(admin_token, privacy_request_id)
  end

  defp assert_public_pages(conn) do
    pages = [
      {"/explorar", "#public-polos"},
      {"/explorar/sobral", "#public-polo"},
      {"/explorar/sobral/lugares/cafe-horizonte-demo-sobral", "#public-place-detail"},
      {"/termos", "#public-legal"}
    ]

    for {path, selector} <- pages do
      assert_live_page(conn |> recycle() |> init_test_session(%{}), path, selector)
    end
  end

  defp assert_member_pages(token) do
    pages = [
      {"/app", "#member-dashboard"},
      {"/app/catalog", "#member-catalog"},
      {"/app/orders", "#member-orders"},
      {"/app/privacy", "#member-privacy"},
      {"/app/profile", "#member-profile"},
      {"/app/subscriptions", "#member-subscriptions"},
      {"/app/wallet", "#member-wallet"}
    ]

    for {path, selector} <- pages do
      assert_authenticated_page(token, path, selector)
    end
  end

  defp assert_backoffice_pages(token) do
    pages = [
      {"/admin?polo=sobral", "#metric-authorized-areas"},
      {"/admin/places?polo=sobral", "#places-page"},
      {"/admin/subscriptions?polo=sobral", "#subscriptions-page"},
      {"/admin/payments?polo=sobral", "#payments-page"},
      {"/admin/platform-billing?polo=sobral", "#platform-billing-page"},
      {"/admin/commercial/benefits?polo=sobral", "#benefit-offers-page"},
      {"/admin/commercial/offerings?polo=sobral", "#product-offerings-page"},
      {"/admin/partners?polo=sobral", "#partners-page"},
      {"/admin/partners/agreements?polo=sobral", "#agreements-page"},
      {"/admin/validation-points?polo=sobral", "#validation-points-page"},
      {"/admin/moderation/reviews?polo=sobral", "#moderation-reviews-page"},
      {"/admin/moderation/reports?polo=sobral", "#moderation-reports-page"},
      {"/admin/operations/outbox?polo=sobral", "#operations-outbox-page"},
      {"/admin/operations/audit?polo=sobral", "#operations-audit-page"}
    ]

    for {path, selector} <- pages do
      assert_authenticated_page(token, path, selector)
    end
  end

  defp assert_partner_pages(token) do
    pages = [
      {"/partner?polo=sobral", "#partner-places-page"},
      {"/partner/places/sobral/#{Ids.fetch!(:polo_place_local_sobral)}", "#partner-place-detail"},
      {"/partner/reviews?polo=sobral", "#partner-reviews-page"}
    ]

    for {path, selector} <- pages do
      assert_authenticated_page(token, path, selector)
    end
  end

  defp assert_platform_pages(token, privacy_request_id) do
    pages = [
      {"/platform", "#platform-dashboard"},
      {"/platform/billing/plans", "#platform-billing-plans-page"},
      {"/platform/privacy/requests", "#platform-privacy-requests-page"},
      {"/platform/privacy/requests/#{privacy_request_id}", "#platform-privacy-request-page"},
      {"/platform/privacy/purposes", "#platform-privacy-purposes-page"}
    ]

    for {path, selector} <- pages do
      assert_authenticated_page(token, path, selector)
    end
  end

  defp assert_authenticated_page(token, path, selector) do
    conn =
      Phoenix.ConnTest.build_conn()
      |> init_test_session(%{"backoffice_session_token" => token})

    assert_live_page(conn, path, selector)
  end

  defp assert_live_page(conn, path, selector) do
    assert {:ok, view, _html} = live(conn, path)
    assert has_element?(view, selector)
  end

  defp login!(email, password) do
    assert {:ok, session} = Accounts.login(email, password)
    session.token
  end
end
