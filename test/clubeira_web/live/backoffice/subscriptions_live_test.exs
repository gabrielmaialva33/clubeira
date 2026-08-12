defmodule ClubeiraWeb.Backoffice.SubscriptionsLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Billing
  alias Clubeira.BillingFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures
  alias Clubeira.Subscriptions

  @password "uma-senha-forte-para-o-inventario-web-de-assinaturas"

  test "lists only the selected polo subscriptions for an authorized admin", %{conn: conn} do
    fixture = BillingFixtures.create!()
    other_polo = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {_order, contract} = captured_subscription!(fixture)
    {_other_order, other_contract} = captured_subscription!(other_polo)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/subscriptions?polo=#{fixture.polo_route.slug}")

    assert has_element?(view, "#subscriptions-page")
    assert has_element?(view, "#subscriptions-inventory #subscription-#{contract.id}")
    refute has_element?(view, "#subscriptions-inventory #subscription-#{other_contract.id}")
    assert has_element?(view, "#backoffice-nav-subscriptions[aria-current='page']")
  end

  test "redirects an actor without billing-management capability", %{conn: conn} do
    fixture = BillingFixtures.create!()

    moderator_scope =
      ReviewsFixtures.grant_moderator!(%{
        ids: %{polo: fixture.polo.id},
        scope: fixture.service_scope
      })

    session = authenticate!(moderator_scope.actor_user_id)
    expected_path = "/admin?polo=#{fixture.polo_route.slug}"

    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(conn, "/admin/subscriptions?polo=#{fixture.polo_route.slug}")
  end

  test "filters contract status through URL state", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {_older_order, suspended_contract} = captured_subscription!(fixture)

    {_newer_order, active_contract} =
      captured_subscription!(fixture, %{
        external_event_id: "evt-#{Ecto.UUID.generate()}",
        provider_reference: "pay-#{Ecto.UUID.generate()}"
      })

    assert {:ok, %{"status" => "suspended"}} =
             Subscriptions.transition_contract(admin_scope, suspended_contract.id, %{
               action: "suspend",
               reason: "Pausa operacional para testar o inventário",
               idempotency_key: "subscriptions-live-filter-suspended"
             })

    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/subscriptions?polo=#{fixture.polo_route.slug}")

    view
    |> form("#subscription-filters", filters: %{status: "suspended", order_number: ""})
    |> render_submit()

    assert_patch(view, "/admin/subscriptions?polo=#{fixture.polo_route.slug}&status=suspended")
    assert has_element?(view, "#subscription-#{suspended_contract.id}")
    refute has_element?(view, "#subscription-#{active_contract.id}")
  end

  test "restores an exact order-number filter from a direct URL", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {expected_order, expected_contract} = captured_subscription!(fixture)

    {_other_order, other_contract} =
      captured_subscription!(fixture, %{
        external_event_id: "evt-#{Ecto.UUID.generate()}",
        provider_reference: "pay-#{Ecto.UUID.generate()}"
      })

    session = authenticate!(admin_scope.actor_user_id)

    query =
      URI.encode_query(%{
        "polo" => fixture.polo_route.slug,
        "order_number" => expected_order.order_number
      })

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/subscriptions?#{query}")

    assert has_element?(
             view,
             "#filters_order_number[value='#{expected_order.order_number}']"
           )

    assert has_element?(view, "#subscription-#{expected_contract.id}")
    refute has_element?(view, "#subscription-#{other_contract.id}")
  end

  test "canonicalizes invalid inventory URL state instead of crashing", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    session = authenticate!(admin_scope.actor_user_id)
    expected_path = "/admin/subscriptions?polo=#{fixture.polo_route.slug}"

    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(conn, "/admin/subscriptions?polo=#{fixture.polo_route.slug}&status=tampered")
  end

  test "advances through the context keyset cursor without retaining the previous page", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {_older_order, older_contract} = captured_subscription!(fixture)

    {_newer_order, newer_contract} =
      captured_subscription!(fixture, %{
        external_event_id: "evt-#{Ecto.UUID.generate()}",
        provider_reference: "pay-#{Ecto.UUID.generate()}"
      })

    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/subscriptions?polo=#{fixture.polo_route.slug}&limit=1")

    assert has_element?(view, "#subscription-#{newer_contract.id}")
    refute has_element?(view, "#subscription-#{older_contract.id}")

    view
    |> element("#subscriptions-next-page")
    |> render_click()

    patched_path = assert_patch(view)
    query = patched_path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert query["polo"] == fixture.polo_route.slug
    assert query["limit"] == "1"
    assert is_binary(query["after"])
    assert has_element?(view, "#subscription-#{older_contract.id}")
    refute has_element?(view, "#subscription-#{newer_contract.id}")
    refute has_element?(view, "#subscriptions-next-page")
  end

  test "keeps the current polo when the switcher receives an unauthorized slug", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/subscriptions?polo=#{fixture.polo_route.slug}")

    render_change(view, "change_polo", %{"context" => %{"polo" => "not-authorized"}})

    assert_patch(view, "/admin/subscriptions?polo=#{fixture.polo_route.slug}")
  end

  test "rejects malformed browser events without terminating the inventory", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {_order, contract} = captured_subscription!(fixture)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/subscriptions?polo=#{fixture.polo_route.slug}")

    render_change(view, "change_polo", %{})
    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#subscription-#{contract.id}")

    render_submit(view, "filter", %{})
    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#subscription-#{contract.id}")
  end

  defp grant_admin!(fixture) do
    ReviewsFixtures.grant_moderator!(
      %{ids: %{polo: fixture.polo.id}, scope: fixture.service_scope},
      role_key: "admin"
    )
  end

  defp captured_subscription!(fixture, overrides \\ %{}) do
    checkout_overrides = %{
      idempotency_key:
        Map.get(overrides, :checkout_idempotency_key, "checkout-#{Ecto.UUID.generate()}")
    }

    assert {:ok, order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture, checkout_overrides)
             )

    settlement_overrides =
      Map.take(overrides, [:external_event_id, :provider_reference, :occurred_at])

    assert {:ok, contract} =
             Billing.settle_payment(
               fixture.service_scope,
               BillingFixtures.settled_payment(fixture, order, settlement_overrides)
             )

    {order, contract}
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session
  end
end
