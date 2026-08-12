defmodule ClubeiraWeb.Backoffice.DashboardLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Billing
  alias Clubeira.BillingFixtures
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  @password "uma-senha-forte-para-o-dashboard"

  test "redirects an anonymous visitor to the panel login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/admin/login"}}} = live(conn, "/admin")
  end

  test "renders the authorized polo and its real operational data", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    user = Repo.get!(User, admin_scope.actor_user_id)

    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)

    {:ok, view, html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin")

    refute html =~ session.token
    assert has_element?(view, "#backoffice-shell")
    assert has_element?(view, "#backoffice-user-email", user.email)
    assert has_element?(view, "#polo-switcher option[value='#{fixture.polo_slug}']")
    assert has_element?(view, "#places-feed #place-#{fixture.ids.polo_place}")
    assert has_element?(view, "#capability-manage-billing")
    assert has_element?(view, "#capability-manage-partners")
    assert has_element?(view, "#metric-authorized-areas")
    assert has_element?(view, "#metric-recent-places")
    assert has_element?(view, "#metric-recent-subscriptions")
    assert has_element?(view, "#metric-recent-payments")
    refute has_element?(view, "#notifications-button")

    assert has_element?(
             view,
             "#backoffice-nav-places[href='/admin/places?polo=#{fixture.polo_slug}']"
           )
  end

  test "formats financial values for the negotiated English locale", %{conn: conn} do
    fixture = BillingFixtures.create!()

    ReviewsFixtures.grant_moderator!(
      %{ids: %{polo: fixture.polo.id}, scope: fixture.member_scope},
      role_key: "admin",
      user_id: fixture.user.id,
      insert_user: false
    )

    assert {:ok, order} =
             Billing.place_order(fixture.member_scope, BillingFixtures.checkout_request(fixture))

    assert {:ok, _settlement} =
             Billing.settle_payment(
               fixture.service_scope,
               BillingFixtures.settled_payment(fixture, order)
             )

    assert {:ok, %{payments: [recorded_payment]}} =
             Billing.list_backoffice_payments(fixture.member_scope, %{"limit" => "5"})

    expected_timestamp =
      Calendar.strftime(recorded_payment.recorded_at, "%Y-%m-%d · %H:%M UTC")

    assert {:ok, _credential} = Accounts.set_password(fixture.user, @password)
    assert {:ok, session} = Accounts.login(fixture.user.email, @password)

    {:ok, view, _html} =
      conn
      |> put_req_header("accept-language", "en")
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin")

    assert has_element?(view, "#payments-feed", "BRL 29.90")
    refute has_element?(view, "#payments-feed", "BRL 29,90")
    assert has_element?(view, "#payments-feed", expected_timestamp)
  end

  test "keeps the current polo when the switcher payload is tampered", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    user = Repo.get!(User, admin_scope.actor_user_id)

    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin")

    render_change(view, "change_polo", %{"context" => %{"polo" => "not-authorized"}})

    assert_patch(view, "/admin?polo=#{fixture.polo_slug}")

    assert has_element?(
             view,
             "#polo-switcher option[value='#{fixture.polo_slug}'][selected]"
           )
  end

  test "switches between authorized polos without retaining tenant data", %{conn: conn} do
    first_fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(first_fixture, role_key: "admin")
    user = Repo.get!(User, admin_scope.actor_user_id)

    second_fixture =
      RedemptionsFixtures.create!(user_id: user.id, insert_user: false)

    ReviewsFixtures.grant_moderator!(second_fixture,
      role_key: "admin",
      user_id: user.id,
      insert_user: false
    )

    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin?polo=#{first_fixture.polo_slug}")

    assert has_element?(view, "#places-feed #place-#{first_fixture.ids.polo_place}")
    refute has_element?(view, "#places-feed #place-#{second_fixture.ids.polo_place}")

    view
    |> form("#polo-switcher", context: %{polo: second_fixture.polo_slug})
    |> render_change()

    assert_patch(view, "/admin?polo=#{second_fixture.polo_slug}")
    assert has_element?(view, "#places-feed #place-#{second_fixture.ids.polo_place}")
    refute has_element?(view, "#places-feed #place-#{first_fixture.ids.polo_place}")
  end

  test "rejects a valid member session without backoffice capabilities", %{conn: conn} do
    user = Clubeira.Factory.insert(:user)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)

    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: "/admin/login"}}} = live(conn, "/admin")
  end

  test "derives the visible modules from the current polo capabilities", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)
    user = Repo.get!(User, moderator_scope.actor_user_id)

    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin")

    assert has_element?(view, "#capability-moderate-reviews")
    refute has_element?(view, "#capability-manage-billing")
    refute has_element?(view, "#capability-manage-partners")
    refute has_element?(view, "#places-section")
    refute has_element?(view, "#payments-section")
    assert has_element?(view, "#metric-authorized-areas")
    refute has_element?(view, "#metric-recent-places")
    refute has_element?(view, "#metric-recent-subscriptions")
    refute has_element?(view, "#metric-recent-payments")
  end
end
