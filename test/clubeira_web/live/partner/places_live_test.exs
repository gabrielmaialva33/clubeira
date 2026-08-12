defmodule ClubeiraWeb.Partner.PlacesLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.RedemptionsFixtures
  alias ClubeiraWeb.PartnerBrowserFixtures

  test "redirects visitors without a current partner assignment", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/partner/login"}}} = live(conn, "/partner")
  end

  test "lists only the current partner's assigned places", %{conn: conn} do
    fixture = RedemptionsFixtures.create!(alternate_validation_place: true)
    other_polo = RedemptionsFixtures.create!()
    partner = PartnerBrowserFixtures.grant_partner!(fixture)
    session = PartnerBrowserFixtures.authenticate!(partner.user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/partner?polo=#{fixture.polo_slug}")

    assert has_element?(view, "#partner-shell")
    assert has_element?(view, "#partner-places-page")
    assert has_element?(view, "#partner-place-#{fixture.ids.polo_place}")
    refute has_element?(view, "#partner-place-#{fixture.ids.other_polo_place}")
    refute has_element?(view, "#partner-place-#{other_polo.ids.polo_place}")
    assert has_element?(view, "#partner-nav-places[aria-current='page']")

    assert has_element?(
             view,
             "#partner-place-link-#{fixture.ids.polo_place}[href='/partner/places/#{fixture.polo_slug}/#{fixture.ids.polo_place}']"
           )
  end

  test "uses the context keyset cursor and rejects a tampered polo", %{conn: conn} do
    fixture = RedemptionsFixtures.create!(alternate_validation_place: true)
    other_polo = RedemptionsFixtures.create!()
    first_access = PartnerBrowserFixtures.grant_partner!(fixture)

    PartnerBrowserFixtures.assign_additional_place!(
      fixture,
      first_access,
      fixture.ids.other_place
    )

    session = PartnerBrowserFixtures.authenticate!(first_access.user)
    authenticated_conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    {:ok, view, _html} =
      live(authenticated_conn, "/partner?polo=#{fixture.polo_slug}&limit=1")

    assert has_element?(view, "#partner-places-next-page")

    view
    |> element("#partner-places-next-page")
    |> render_click()

    patched_path = assert_patch(view)
    query = patched_path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert query["polo"] == fixture.polo_slug
    assert query["limit"] == "1"
    assert is_binary(query["after"])

    expected_path = "/partner?polo=#{fixture.polo_slug}"

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(authenticated_conn, "/partner?polo=#{other_polo.polo_slug}")
  end

  test "revoked global affiliation is rejected on the next mount", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    partner = PartnerBrowserFixtures.grant_partner!(fixture)
    session = PartnerBrowserFixtures.authenticate!(partner.user)

    PartnerBrowserFixtures.revoke_organization_membership!(partner.organization_membership)

    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: "/partner/login"}}} =
             live(conn, "/partner?polo=#{fixture.polo_slug}")
  end

  test "canonicalizes an invalid cursor and survives a malformed polo event", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    partner = PartnerBrowserFixtures.grant_partner!(fixture)
    session = PartnerBrowserFixtures.authenticate!(partner.user)
    authenticated_conn = init_test_session(conn, %{"backoffice_session_token" => session.token})
    canonical = "/partner?polo=#{fixture.polo_slug}"

    assert {:error, {:redirect, %{to: ^canonical}}} =
             live(authenticated_conn, "#{canonical}&after=malformed")

    {:ok, view, _html} = live(authenticated_conn, canonical)
    render_hook(view, "change_polo", %{})

    assert has_element?(view, "#partner-places-page")
    assert has_element?(view, "#flash-error")
  end
end
