defmodule ClubeiraWeb.Backoffice.PlacesLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  @password "uma-senha-forte-para-o-inventario-web"

  test "lists only the selected polo participations for an authorized admin", %{conn: conn} do
    fixture = RedemptionsFixtures.create!(alternate_validation_place: true)
    other_polo = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/places?polo=#{fixture.polo_slug}")

    assert has_element?(view, "#places-page")
    assert has_element?(view, "#places-inventory #place-#{fixture.ids.polo_place}")
    assert has_element?(view, "#places-inventory #place-#{fixture.ids.other_polo_place}")
    refute has_element?(view, "#places-inventory #place-#{other_polo.ids.polo_place}")
    assert has_element?(view, "#backoffice-nav-places[aria-current='page']")

    assert has_element?(
             view,
             "#place-link-#{fixture.ids.polo_place}[href='/admin/places/#{fixture.ids.polo_place}?polo=#{fixture.polo_slug}']"
           )
  end

  test "redirects a backoffice actor without partner-management capability", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)
    session = authenticate!(moderator_scope.actor_user_id)

    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})
    expected_path = "/admin?polo=#{fixture.polo_slug}"

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(conn, "/admin/places?polo=#{fixture.polo_slug}")
  end

  test "filters participation status through URL state", %{conn: conn} do
    fixture =
      RedemptionsFixtures.create!(
        alternate_validation_place: true,
        polo_place_status: "suspended"
      )

    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/places?polo=#{fixture.polo_slug}")

    view
    |> form("#place-filters", filters: %{status: "suspended", profile_status: ""})
    |> render_change()

    assert_patch(view, "/admin/places?polo=#{fixture.polo_slug}&status=suspended")
    assert has_element?(view, "#places-inventory #place-#{fixture.ids.polo_place}")
    refute has_element?(view, "#places-inventory #place-#{fixture.ids.other_polo_place}")
  end

  test "restores the public-profile filter from a direct URL", %{conn: conn} do
    fixture = RedemptionsFixtures.create!(alternate_validation_place: true)
    _profile_id = insert_profile!(fixture, fixture.ids.other_polo_place)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/places?polo=#{fixture.polo_slug}&profile_status=published")

    assert has_element?(view, "#places-inventory #place-#{fixture.ids.other_polo_place}")
    refute has_element?(view, "#places-inventory #place-#{fixture.ids.polo_place}")

    assert has_element?(
             view,
             "#filters_profile_status option[value='published'][selected]"
           )

    assert has_element?(view, "#places-inventory", "operacao@example.test")
  end

  test "canonicalizes invalid inventory URL state instead of crashing", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)
    expected_path = "/admin/places?polo=#{fixture.polo_slug}"

    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(conn, "/admin/places?polo=#{fixture.polo_slug}&status=tampered")
  end

  test "advances through the context keyset cursor without retaining the previous page", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!(alternate_validation_place: true)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/places?polo=#{fixture.polo_slug}&limit=1")

    participation_ids = [fixture.ids.polo_place, fixture.ids.other_polo_place]
    first_id = Enum.find(participation_ids, &has_element?(view, "#place-#{&1}"))
    second_id = Enum.find(participation_ids, &(&1 != first_id))

    assert is_binary(first_id)
    refute has_element?(view, "#place-#{second_id}")

    view
    |> element("#places-next-page")
    |> render_click()

    patched_path = assert_patch(view)
    query = patched_path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert query["polo"] == fixture.polo_slug
    assert query["limit"] == "1"
    assert is_binary(query["after"])
    assert has_element?(view, "#place-#{second_id}")
    refute has_element?(view, "#place-#{first_id}")
    refute has_element?(view, "#places-next-page")
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session
  end

  defp insert_profile!(fixture, polo_place_id) do
    profile_id = Ecto.UUID.generate(version: 7, precision: :monotonic)

    assert %{num_rows: 1} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               INSERT INTO polo_place_profiles (
                 id,
                 polo_id,
                 polo_place_id,
                 public_email,
                 public_phone,
                 revision
               )
               VALUES ($1, $2, $3, 'operacao@example.test', '+5511999990000', 1)
               """,
               [profile_id, fixture.ids.polo, polo_place_id]
             )

    profile_id
  end
end
