defmodule ClubeiraWeb.Member.OrdersLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.Billing
  alias Clubeira.Billing.Gateways.MercadoPago
  alias Clubeira.BillingFixtures
  alias Clubeira.Factory
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  @password "uma-senha-forte-para-os-pedidos-do-membro"

  test "lists only the current actor orders in the selected polo", %{conn: conn} do
    fixture = BillingFixtures.create!()
    other_polo = BillingFixtures.create!()
    own_order = place_order!(fixture.member_scope, fixture, "orders-live-owner")

    another_user = Factory.insert(:user)
    another_scope = Scope.new!(fixture.polo.id, actor_user_id: another_user.id)
    another_order = place_order!(another_scope, fixture, "orders-live-other")
    session = authenticate!(fixture.user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/orders?polo=#{fixture.polo_route.slug}")

    assert has_element?(view, "#member-orders")
    assert has_element?(view, "#member-order-#{own_order.id}")
    refute has_element?(view, "#member-order-#{another_order.id}")
    assert has_element?(view, "#member-nav-orders[aria-current='page']")

    view
    |> form("#orders-polo-switcher", orders: %{polo: other_polo.polo_route.slug})
    |> render_change()

    assert_patch(view, "/app/orders?polo=#{other_polo.polo_route.slug}")
    refute has_element?(view, "#member-order-#{own_order.id}")
  end

  test "resumes Pix payment for an awaiting order", %{conn: conn} do
    fixture = BillingFixtures.create!()
    configure_mercado_pago!(fixture)
    order = place_order!(fixture.member_scope, fixture, "orders-live-payment")
    session = authenticate!(fixture.user)
    pix_code = "000201010212clubeira-orders-live-pix"

    Req.Test.expect(MercadoPago, fn request ->
      request
      |> Plug.Conn.put_status(:created)
      |> Req.Test.json(%{
        id: "ORD-ORDERS-LIVE",
        status: "action_required",
        transactions: %{
          payments: [
            %{
              id: "PAY-ORDERS-LIVE",
              status: "action_required",
              status_detail: "waiting_transfer",
              amount: "29.90",
              payment_method: %{
                id: "pix",
                type: "bank_transfer",
                ticket_url: "https://www.mercadopago.com.br/sandbox/ticket/orders-live",
                qr_code: pix_code,
                qr_code_base64: "ignored"
              }
            }
          ]
        }
      })
    end)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/orders?polo=#{fixture.polo_route.slug}")

    view |> element("#pay-order-#{order.id}") |> render_click()

    assert has_element?(view, "#order-payment-result")
    assert has_element?(view, "#order-payment-pix-code", pix_code)
  end

  test "keeps historical orders reachable after a polo leaves the public directory", %{conn: conn} do
    fixture = BillingFixtures.create!()
    order = place_order!(fixture.member_scope, fixture, "orders-live-inactive-polo")

    assert {:ok, _contract} =
             Billing.settle_payment(
               fixture.service_scope,
               BillingFixtures.settled_payment(fixture, order)
             )

    assert {:ok, _polo} =
             Repo.transact_in_polo(fixture.service_scope, fn ->
               fixture.polo
               |> Ecto.Changeset.change(status: "suspended")
               |> Repo.update()
             end)

    session = authenticate!(fixture.user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/orders?polo=#{fixture.polo_route.slug}")

    assert has_element?(view, "#member-order-#{order.id}")
    assert has_element?(view, "#orders-polo option[value='#{fixture.polo_route.slug}'][selected]")
  end

  test "does not resume automatic renewal before member cancellation is operational", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()

    assert {:ok, _offering_version} =
             Repo.transact_in_polo(fixture.member_scope, fn ->
               fixture.offering_version
               |> Ecto.Changeset.change(renewal_policy: "automatic")
               |> Repo.update()
             end)

    order = place_order!(fixture.member_scope, fixture, "orders-live-automatic")
    session = authenticate!(fixture.user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/orders?polo=#{fixture.polo_route.slug}")

    refute has_element?(view, "#pay-order-#{order.id}")
    render_click(view, "pay_order", %{"order-id" => order.id})
    assert has_element?(view, "#flash-error")
    assert {:ok, %{agreements: []}} = Billing.read_account_billing(fixture.member_scope)
  end

  test "canonicalizes pagination and rejects malformed payment events", %{conn: conn} do
    fixture = BillingFixtures.create!()
    order = place_order!(fixture.member_scope, fixture, "orders-live-invalid-events")
    session = authenticate!(fixture.user)
    authenticated_conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: "/app/orders"}}} =
             live(
               authenticated_conn,
               "/app/orders?polo=#{fixture.polo_route.slug}&after=malformed"
             )

    {:ok, view, _html} =
      live(authenticated_conn, "/app/orders?polo=#{fixture.polo_route.slug}")

    render_hook(view, "change_orders_polo", %{})
    render_hook(view, "pay_order", %{})
    render_hook(view, "pay_order", %{"order-id" => Ecto.UUID.generate(version: 7)})

    assert has_element?(view, "#member-orders")
    assert has_element?(view, "#flash-error")
    refute has_element?(view, "#order-payment-result")
    assert has_element?(view, "#member-order-#{order.id}")
  end

  test "revalidates the session immediately before resuming payment", %{conn: conn} do
    fixture = BillingFixtures.create!()
    order = place_order!(fixture.member_scope, fixture, "orders-live-revoked-session")
    session = authenticate!(fixture.user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/orders?polo=#{fixture.polo_route.slug}")

    assert {:ok, account_scope} = Accounts.fetch_scope_by_api_token(session.token)
    assert :ok = Accounts.revoke_session(account_scope)

    assert {:error, {:redirect, %{to: "/app/login"}}} =
             view |> element("#pay-order-#{order.id}") |> render_click()
  end

  test "keeps an awaiting order available when the PSP cannot resume Pix", %{conn: conn} do
    fixture = BillingFixtures.create!()
    configure_mercado_pago!(fixture)
    order = place_order!(fixture.member_scope, fixture, "orders-live-provider-unavailable")
    session = authenticate!(fixture.user)

    Req.Test.expect(MercadoPago, fn request ->
      request
      |> Plug.Conn.put_status(:service_unavailable)
      |> Req.Test.json(%{message: "temporarily unavailable"})
    end)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/orders?polo=#{fixture.polo_route.slug}")

    view |> element("#pay-order-#{order.id}") |> render_click()

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#member-order-#{order.id}")
    refute has_element?(view, "#order-payment-result")
  end

  test "replaces the current keyset page when browsing order history", %{conn: conn} do
    fixture = BillingFixtures.create!()

    orders = [
      place_order!(fixture.member_scope, fixture, "orders-live-page-one"),
      place_order!(fixture.member_scope, fixture, "orders-live-page-two")
    ]

    session = authenticate!(fixture.user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/orders?polo=#{fixture.polo_route.slug}&limit=1")

    [visible] = Enum.filter(orders, &has_element?(view, "#member-order-#{&1.id}"))
    assert has_element?(view, "#member-orders-next-page")

    view |> element("#member-orders-next-page") |> render_click()
    assert_patch(view)

    refute has_element?(view, "#member-order-#{visible.id}")
    assert Enum.any?(orders -- [visible], &has_element?(view, "#member-order-#{&1.id}"))
  end

  test "renders terminal and fallback order states including an unavailable timestamp", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()

    [cancelled, expired, refunded] =
      for {status, suffix} <- [
            {"cancelled", "cancelled"},
            {"expired", "expired"},
            {"refunded", "refunded"}
          ] do
        place_order!(fixture.member_scope, fixture, "orders-live-#{suffix}")
        |> set_order_state!(fixture, status)
      end

    assert {:ok, empty_pending} =
             Repo.transact_in_polo(fixture.member_scope, fn ->
               {:ok,
                Factory.insert(:order,
                  polo: fixture.polo,
                  purchaser_user: fixture.user,
                  status: "pending",
                  placed_at: nil
                )}
             end)

    session = authenticate!(fixture.user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/orders?polo=#{fixture.polo_route.slug}")

    assert has_element?(view, "#member-order-#{cancelled.id}", "Cancelado")
    assert has_element?(view, "#member-order-#{expired.id}", "Expirado")
    assert has_element?(view, "#member-order-#{refunded.id}", "refunded")
    assert has_element?(view, "#member-order-#{empty_pending.id}", "Não disponível")
    refute has_element?(view, "#pay-order-#{empty_pending.id}")
  end

  defp place_order!(scope, fixture, idempotency_key) do
    assert {:ok, order} =
             Billing.place_order(
               scope,
               BillingFixtures.checkout_request(fixture, idempotency_key: idempotency_key)
             )

    order
  end

  defp set_order_state!(order, fixture, status) do
    assert {:ok, updated} =
             Repo.transact_in_polo(fixture.member_scope, fn ->
               order
               |> Ecto.Changeset.change(status: status)
               |> Repo.update()
             end)

    updated
  end

  defp configure_mercado_pago!(fixture) do
    fixture.provider
    |> Ecto.Changeset.change(code: "mercado_pago")
    |> Clubeira.Repo.update!()

    previous = Application.get_env(:clubeira, MercadoPago)

    Application.put_env(:clubeira, MercadoPago,
      accounts: %{
        fixture.merchant_account.provider_account_reference => %{
          access_token: "orders-live-token",
          webhook_secret: "orders-live-webhook-secret-with-32-bytes"
        }
      },
      req_options: [plug: {Req.Test, MercadoPago}]
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:clubeira, MercadoPago, previous),
        else: Application.delete_env(:clubeira, MercadoPago)
    end)
  end

  defp authenticate!(user) do
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session
  end
end
