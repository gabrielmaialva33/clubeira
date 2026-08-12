defmodule ClubeiraWeb.Backoffice.PaymentsLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Billing
  alias Clubeira.BillingFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures
  alias Clubeira.TestDatabaseRole

  @password "uma-senha-forte-para-o-inventario-web-financeiro"

  test "lists only the selected polo payments for an authorized admin", %{conn: conn} do
    fixture = BillingFixtures.create!()
    other_polo = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    other_admin_scope = grant_admin!(other_polo)
    {_order, payment} = captured_payment!(fixture, admin_scope)
    {_other_order, other_payment} = captured_payment!(other_polo, other_admin_scope)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/payments?polo=#{fixture.polo_route.slug}")

    assert has_element?(view, "#payments-page")
    assert has_element?(view, "#payments-inventory #payment-#{payment.id}")
    refute has_element?(view, "#payments-inventory #payment-#{other_payment.id}")
    assert has_element?(view, "#backoffice-nav-finance[aria-current='page']")
  end

  test "filters by exact order number through URL state", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {expected_order, expected_payment} = captured_payment!(fixture, admin_scope)

    {_other_order, other_payment} =
      captured_payment!(fixture, admin_scope, %{
        external_event_id: "evt-#{Ecto.UUID.generate()}",
        provider_reference: "pay-#{Ecto.UUID.generate()}"
      })

    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/payments?polo=#{fixture.polo_route.slug}")

    view
    |> form("#payment-filters",
      filters: %{status: "", order_number: expected_order.order_number}
    )
    |> render_submit()

    patched_path = assert_patch(view)
    query = patched_path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert query == %{
             "polo" => fixture.polo_route.slug,
             "order_number" => expected_order.order_number
           }

    assert has_element?(view, "#payment-#{expected_payment.id}")
    refute has_element?(view, "#payment-#{other_payment.id}")
  end

  test "advances through the context keyset cursor without retaining the previous page", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {_older_order, older_payment} = captured_payment!(fixture, admin_scope)

    {_newer_order, newer_payment} =
      captured_payment!(fixture, admin_scope, %{
        external_event_id: "evt-#{Ecto.UUID.generate()}",
        provider_reference: "pay-#{Ecto.UUID.generate()}"
      })

    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/payments?polo=#{fixture.polo_route.slug}&limit=1")

    assert has_element?(view, "#payment-#{newer_payment.id}")
    refute has_element?(view, "#payment-#{older_payment.id}")

    view
    |> element("#payments-next-page")
    |> render_click()

    patched_path = assert_patch(view)
    query = patched_path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert query["polo"] == fixture.polo_route.slug
    assert query["limit"] == "1"
    assert is_binary(query["after"])
    assert has_element?(view, "#payment-#{older_payment.id}")
    refute has_element?(view, "#payment-#{newer_payment.id}")
    refute has_element?(view, "#payments-next-page")
  end

  test "canonicalizes invalid inventory URL state instead of crashing", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    session = authenticate!(admin_scope.actor_user_id)
    expected_path = "/admin/payments?polo=#{fixture.polo_route.slug}"

    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(conn, "/admin/payments?polo=#{fixture.polo_route.slug}&status=tampered")
  end

  test "rejects a malformed filter event without dropping the live inventory", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {_order, payment} = captured_payment!(fixture, admin_scope)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/payments?polo=#{fixture.polo_route.slug}")

    render_hook(view, "filter", %{"filters" => "not-a-map"})

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#payments-inventory #payment-#{payment.id}")
  end

  test "a revoked polo membership cannot refresh the payment inventory", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/payments?polo=#{fixture.polo_route.slug}")

    TestDatabaseRole.as_owner(fn ->
      Repo.query!(
        "UPDATE polo_memberships SET status = 'revoked' WHERE polo_id = $1 AND user_id = $2",
        [Ecto.UUID.dump!(fixture.polo.id), Ecto.UUID.dump!(admin_scope.actor_user_id)]
      )
    end)

    view
    |> form("#payment-filters", filters: %{status: "captured", order_number: ""})
    |> render_submit()

    assert_redirect(view, "/admin?polo=#{fixture.polo_route.slug}")
  end

  defp grant_admin!(fixture) do
    ReviewsFixtures.grant_moderator!(
      %{ids: %{polo: fixture.polo.id}, scope: fixture.service_scope},
      role_key: "admin"
    )
  end

  defp captured_payment!(fixture, admin_scope, overrides \\ %{}) do
    assert {:ok, order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture, %{
                 idempotency_key: "payments-live-checkout-#{Ecto.UUID.generate()}"
               })
             )

    assert {:ok, _contract} =
             Billing.settle_payment(
               fixture.service_scope,
               BillingFixtures.settled_payment(fixture, order, overrides)
             )

    assert {:ok, %{payments: [payment]}} =
             Billing.list_backoffice_payments(admin_scope, %{"limit" => "1"})

    {order, payment}
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session
  end
end
