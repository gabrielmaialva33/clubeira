defmodule ClubeiraWeb.Platform.DashboardLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.PrivacyFixtures
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  @password "uma-senha-forte-para-a-plataforma"

  test "redirects an anonymous visitor to the platform login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/platform/login"}}} = live(conn, "/platform")
  end

  test "renders the global shell for a platform-only user without selecting a polo", %{conn: conn} do
    user = platform_user!()
    session = login!(user)

    {:ok, view, html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/platform")

    refute html =~ session.token
    assert has_element?(view, "#platform-shell")
    assert has_element?(view, "#platform-user-email", user.email)
    assert has_element?(view, "#platform-nav-overview[aria-current='page']")
    assert has_element?(view, "#platform-capability-manage-privacy")
    refute has_element?(view, "#platform-nav-billing")
    refute has_element?(view, "#polo-switcher")
    refute has_element?(view, "#backoffice-shell")
  end

  test "keeps ordinary and tenant-only users out of the global platform", %{conn: conn} do
    ordinary_session = login!(Clubeira.Factory.insert(:user))

    ordinary_conn =
      init_test_session(conn, %{"backoffice_session_token" => ordinary_session.token})

    assert {:error, {:redirect, %{to: "/platform/login"}}} =
             live(ordinary_conn, "/platform")

    fixture = RedemptionsFixtures.create!()
    tenant_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    tenant_user = Repo.get!(User, tenant_scope.actor_user_id)
    tenant_session = login!(tenant_user)

    tenant_conn =
      conn
      |> recycle()
      |> init_test_session(%{"backoffice_session_token" => tenant_session.token})

    assert {:error, {:redirect, %{to: "/platform/login"}}} =
             live(tenant_conn, "/platform")
  end

  test "revalidates the platform role when the LiveView mounts", %{conn: conn} do
    user = Clubeira.Factory.insert(:user)
    %{membership: membership} = PrivacyFixtures.privacy_officer!(user)
    session = login!(user)

    membership
    |> Ecto.Changeset.change(status: "revoked")
    |> Repo.update!()

    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: "/platform/login"}}} = live(conn, "/platform")
  end

  test "revalidates the persisted session when the LiveView mounts", %{conn: conn} do
    user = platform_user!()
    session = login!(user)
    assert {:ok, scope} = Accounts.fetch_scope_by_api_token(session.token)
    assert :ok = Accounts.revoke_session(scope)

    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: "/platform/login"}}} = live(conn, "/platform")
  end

  test "revalidates the active user when the LiveView mounts", %{conn: conn} do
    user = platform_user!()
    session = login!(user)

    user
    |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:microsecond))
    |> Repo.update!()

    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: "/platform/login"}}} = live(conn, "/platform")
  end

  defp platform_user! do
    user = Clubeira.Factory.insert(:user)
    PrivacyFixtures.privacy_officer!(user)
    user
  end

  defp login!(user) do
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session
  end
end
