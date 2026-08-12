defmodule ClubeiraWeb.Partner.PlaceLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Directory
  alias Clubeira.Factory
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Tenancy.Scope
  alias ClubeiraWeb.PartnerBrowserFixtures

  test "opens one exact assigned place and publishes its complete profile", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    other_polo = RedemptionsFixtures.create!()
    partner = PartnerBrowserFixtures.grant_partner!(fixture)
    session = PartnerBrowserFixtures.authenticate!(partner.user)
    Factory.insert(:place_category, key: "cafe", name: "Café")

    {:ok, view, html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/partner/places/#{fixture.polo_slug}/#{fixture.ids.polo_place}")

    refute html =~ session.token
    assert has_element?(view, "#partner-place-detail")
    assert has_element?(view, "#partner-place-name")
    assert has_element?(view, "#partner-place-profile-form")
    assert has_element?(view, "#partner-nav-places[aria-current='page']")

    render_hook(view, "save_profile", %{
      "profile" => %{
        "public_email" => "contato@parceiro.example",
        "public_phone" => "(88) 99999-0101",
        "category_keys" => ["cafe"],
        "weekly_hours" => %{
          "0" => %{"weekday" => "1", "opens_at" => "08:00", "closes_at" => "18:00"}
        },
        "expected_polo_place_id" => other_polo.ids.polo_place,
        "expected_revision" => "999",
        "idempotency_key" => "browser-tampering"
      }
    })

    assert has_element?(view, "#partner-place-profile-revision", "1")
    assert has_element?(view, "#profile_public_email[value='contato@parceiro.example']")

    scope = Scope.new!(fixture.ids.polo, actor_user_id: partner.user.id)

    assert {:ok, %{profile: profile}} =
             Directory.get_partner_place(scope, fixture.ids.polo_place)

    assert profile.revision == 1
    assert profile.public_email == "contato@parceiro.example"
    assert [%{key: "cafe"}] = profile.categories

    render_hook(view, "change_polo", %{
      "context" => %{"polo" => "not-an-authorized-polo"}
    })

    assert_redirect(view, "/partner?polo=#{fixture.polo_slug}")
  end

  test "rejects cross-polo and malformed place identities without exposing details", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    other_polo = RedemptionsFixtures.create!()
    partner = PartnerBrowserFixtures.grant_partner!(fixture)
    session = PartnerBrowserFixtures.authenticate!(partner.user)
    authenticated_conn = init_test_session(conn, %{"backoffice_session_token" => session.token})
    expected_path = "/partner?polo=#{fixture.polo_slug}"

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(
               authenticated_conn,
               "/partner/places/#{fixture.polo_slug}/#{other_polo.ids.polo_place}"
             )

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(authenticated_conn, "/partner/places/#{fixture.polo_slug}/not-a-uuid")

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             authenticated_conn
             |> recycle()
             |> init_test_session(%{"backoffice_session_token" => session.token})
             |> live("/partner/places/not-an-authorized-polo/#{fixture.ids.polo_place}")
  end

  test "revalidates the global affiliation immediately before a profile mutation", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    partner = PartnerBrowserFixtures.grant_partner!(fixture)
    session = PartnerBrowserFixtures.authenticate!(partner.user)
    Factory.insert(:place_category, key: "cafe", name: "Café")

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/partner/places/#{fixture.polo_slug}/#{fixture.ids.polo_place}")

    PartnerBrowserFixtures.revoke_organization_membership!(partner.organization_membership)

    view
    |> form("#partner-place-profile-form",
      profile: %{
        public_email: "bloqueado@parceiro.example",
        public_phone: "+5588999990101",
        category_keys: ["cafe"]
      }
    )
    |> render_submit()

    assert_redirect(view, "/partner/login")

    assert %{rows: [[0]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               "SELECT count(*) FROM polo_place_profiles WHERE polo_place_id = $1",
               [fixture.ids.polo_place]
             )
  end

  test "keeps the LiveView alive for malformed profile events", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    partner = PartnerBrowserFixtures.grant_partner!(fixture)
    session = PartnerBrowserFixtures.authenticate!(partner.user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/partner/places/#{fixture.polo_slug}/#{fixture.ids.polo_place}")

    view
    |> form("#partner-place-profile-form",
      profile: %{public_email: "invalid", public_phone: "invalid"}
    )
    |> render_change()

    assert has_element?(view, "#profile_public_email.border-red-500")

    view
    |> form("#partner-place-profile-form",
      profile: %{public_email: "invalid", public_phone: "invalid"}
    )
    |> render_submit()

    assert has_element?(view, "#profile_public_email.border-red-500")
    assert has_element?(view, "#flash-error")

    render_hook(view, "validate_profile", %{})
    render_hook(view, "save_profile", %{"profile" => "not-a-map"})
    render_hook(view, "change_polo", %{})

    assert has_element?(view, "#partner-place-detail")
    assert has_element?(view, "#flash-error")
  end

  test "keeps unavailable categories as a visible form error without partial writes", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    partner = PartnerBrowserFixtures.grant_partner!(fixture)
    session = PartnerBrowserFixtures.authenticate!(partner.user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/partner/places/#{fixture.polo_slug}/#{fixture.ids.polo_place}")

    render_hook(view, "save_profile", %{
      "profile" => %{
        "public_email" => "contato@parceiro.example",
        "public_phone" => "+5588999990101",
        "category_keys" => ["categoria-inexistente"]
      }
    })

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#profile_category_keys.border-red-500")

    assert %{rows: [[0]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               "SELECT count(*) FROM polo_place_profiles WHERE polo_place_id = $1",
               [fixture.ids.polo_place]
             )
  end

  test "maps domain contact errors back onto the public profile form", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    partner = PartnerBrowserFixtures.grant_partner!(fixture)
    session = PartnerBrowserFixtures.authenticate!(partner.user)
    Factory.insert(:place_category, key: "cafe", name: "Café")

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/partner/places/#{fixture.polo_slug}/#{fixture.ids.polo_place}")

    render_hook(view, "save_profile", %{
      "profile" => %{
        "public_email" => "contato@parceiro.example",
        "public_phone" => "telefone-invalido",
        "category_keys" => ["cafe"],
        "weekly_hours" => %{
          "0" => %{"weekday" => "1", "opens_at" => "08:00", "closes_at" => "18:00"}
        }
      }
    })

    assert has_element?(view, "#profile_public_phone.border-red-500")
    assert has_element?(view, "#flash-error")

    assert %{rows: [[0]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               "SELECT count(*) FROM polo_place_profiles WHERE polo_place_id = $1",
               [fixture.ids.polo_place]
             )
  end

  test "reauthorizes the partner when route params reload", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    partner = PartnerBrowserFixtures.grant_partner!(fixture)
    session = PartnerBrowserFixtures.authenticate!(partner.user)
    path = "/partner/places/#{fixture.polo_slug}/#{fixture.ids.polo_place}"

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(path)

    PartnerBrowserFixtures.revoke_organization_membership!(partner.organization_membership)
    render_patch(view, path)

    assert_redirect(view, "/partner?polo=#{fixture.polo_slug}")
  end

  test "reloads the current profile after a concurrent revision wins", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    partner = PartnerBrowserFixtures.grant_partner!(fixture)
    session = PartnerBrowserFixtures.authenticate!(partner.user)
    category = Factory.insert(:place_category, key: "cafe", name: "Café")

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/partner/places/#{fixture.polo_slug}/#{fixture.ids.polo_place}")

    scope = Scope.new!(fixture.ids.polo, actor_user_id: partner.user.id)

    assert {:ok, _profile} =
             Directory.publish_place_profile(scope, fixture.ids.place, %{
               contact: %{email: "vencedor@parceiro.example", phone: "+5588999990102"},
               category_keys: [category.key],
               weekly_hours: [%{weekday: 1, opens_at: "08:00", closes_at: "18:00"}],
               special_hours: [],
               expected_polo_place_id: fixture.ids.polo_place,
               expected_revision: 0,
               idempotency_key: "partner-concurrent-profile-#{Ecto.UUID.generate(version: 7)}"
             })

    view
    |> form("#partner-place-profile-form",
      profile: %{
        public_email: "perdedor@parceiro.example",
        public_phone: "+5588999990103",
        category_keys: [category.key]
      }
    )
    |> render_submit()

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#partner-place-profile-revision", "1")
    assert has_element?(view, "#profile_public_email[value='vencedor@parceiro.example']")

    assert {:ok, %{profile: profile}} =
             Directory.get_partner_place(scope, fixture.ids.polo_place)

    assert profile.public_email == "vencedor@parceiro.example"
    assert profile.revision == 1
  end

  test "does not publish a profile after the assigned participation is retired", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    partner = PartnerBrowserFixtures.grant_partner!(fixture)
    session = PartnerBrowserFixtures.authenticate!(partner.user)
    Factory.insert(:place_category, key: "cafe", name: "Café")

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/partner/places/#{fixture.polo_slug}/#{fixture.ids.polo_place}")

    assert %{num_rows: 1} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               UPDATE polo_places
               SET status = 'retired',
                   participation_during = tstzrange(lower(participation_during), statement_timestamp(), '[)'),
                   revision = revision + 1
               WHERE id = $1
               """,
               [fixture.ids.polo_place]
             )

    render_hook(view, "save_profile", %{
      "profile" => %{
        "public_email" => "retirado@parceiro.example",
        "public_phone" => "+5588999990101",
        "category_keys" => ["cafe"],
        "weekly_hours" => %{
          "0" => %{"weekday" => "1", "opens_at" => "08:00", "closes_at" => "18:00"}
        }
      }
    })

    assert_redirect(view, "/partner/login")

    assert %{rows: [[0]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               "SELECT count(*) FROM polo_place_profiles WHERE polo_place_id = $1",
               [fixture.ids.polo_place]
             )
  end
end
