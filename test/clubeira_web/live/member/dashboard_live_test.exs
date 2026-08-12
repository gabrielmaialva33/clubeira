defmodule ClubeiraWeb.Member.DashboardLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo

  @password "uma-senha-forte-para-o-app-do-membro"

  test "redirects an anonymous visitor to the member login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/app/login"}}} = live(conn, "/app")
  end

  test "renders a member workspace without requiring a tenant role", %{conn: conn} do
    user = Clubeira.Factory.insert(:user)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)

    {:ok, view, html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app")

    refute html =~ session.token
    assert has_element?(view, "#member-shell")
    assert has_element?(view, "#member-dashboard")
    assert has_element?(view, "#member-nav-overview[aria-current='page']")
    assert has_element?(view, "#member-account-menu", user.email)
  end

  test "renders the authenticated member recent subscriptions", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()

    other_contracts =
      for status <- ~w(pending past_due suspended cancelled) do
        RedemptionsFixtures.create!(
          user_id: fixture.ids.user,
          insert_user: false,
          contract_status: status
        )
      end

    user = Repo.get!(User, fixture.ids.user)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app")

    assert has_element?(view, "#member-dashboard-subscription-count", "5")
    assert has_element?(view, "#member-subscription-#{fixture.ids.access_contract}")

    for contract <- other_contracts do
      assert has_element?(view, "#member-subscription-#{contract.ids.access_contract}")
    end

    assert has_element?(view, "#member-dashboard-subscriptions", "Ativo")
    assert has_element?(view, "#member-dashboard-subscriptions", "Pendente")
    assert has_element?(view, "#member-dashboard-subscriptions", "Inadimplente")
    assert has_element?(view, "#member-dashboard-subscriptions", "Suspenso")
    assert has_element?(view, "#member-dashboard-subscriptions", "Cancelado")
  end
end
