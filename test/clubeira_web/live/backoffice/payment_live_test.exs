defmodule ClubeiraWeb.Backoffice.PaymentLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Billing
  alias Clubeira.Billing.Gateways.MercadoPago
  alias Clubeira.BillingFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  @password "uma-senha-forte-para-pagamentos"
  @access_token "test-payment-live-access-token"
  @webhook_secret "test-payment-live-webhook-secret-with-32-bytes"

  test "an authorized admin opens a safe payment detail from the dashboard", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {order, payment} = captured_payment!(fixture, admin_scope)
    session = authenticate!(admin_scope.actor_user_id)

    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    {:ok, dashboard, _html} = live(conn, "/admin?polo=#{fixture.polo_route.slug}")

    detail_path = "/admin/payments/#{payment.id}?polo=#{fixture.polo_route.slug}"

    assert has_element?(
             dashboard,
             "#payments-feed #payment-#{payment.id}[href='#{detail_path}']"
           )

    {:ok, detail, _html} =
      dashboard |> element("#payment-#{payment.id}") |> render_click() |> follow_redirect(conn)

    assert has_element?(detail, "#payment-detail")
    assert has_element?(detail, "#payment-detail-status[data-status='captured']")
    assert has_element?(detail, "#payment-detail-amount", "BRL 29,90")
    assert has_element?(detail, "#payment-detail-order", order.order_number)
    assert has_element?(detail, "#payment-detail-order-status[data-status='paid']")
    refute has_element?(detail, "[data-provider-reference]")
  end

  test "an admin issues a full refund and sees the settled state without leaving the detail", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {order, payment} = captured_payment!(fixture, admin_scope)
    session = authenticate!(admin_scope.actor_user_id)
    configure_mercado_pago!(fixture)

    Req.Test.expect(MercadoPago, fn request ->
      request
      |> Plug.Conn.put_status(:created)
      |> Req.Test.json(refund_order_response(fixture, order, "refund-live-provider-reference"))
    end)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/payments/#{payment.id}?polo=#{fixture.polo_route.slug}")

    view
    |> form("[id^='payment-refund-form-']",
      refund: %{reason: "Cancelamento confirmado pelo atendimento"}
    )
    |> render_submit()

    assert has_element?(view, "#payment-detail-status[data-status='refunded']")
    assert has_element?(view, "#payment-detail-order-status[data-status='refunded']")
    assert has_element?(view, "#payment-refund-summary [data-status='succeeded']")
    assert has_element?(view, "#payment-refund-unavailable")
    refute has_element?(view, "[id^='payment-refund-form-']")
  end

  defp grant_admin!(fixture) do
    ReviewsFixtures.grant_moderator!(
      %{ids: %{polo: fixture.polo.id}, scope: fixture.service_scope},
      role_key: "admin"
    )
  end

  defp captured_payment!(fixture, admin_scope) do
    assert {:ok, order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture, %{
                 idempotency_key: "payment-live-checkout-#{Ecto.UUID.generate()}"
               })
             )

    assert {:ok, _contract} =
             Billing.settle_payment(
               fixture.service_scope,
               BillingFixtures.settled_payment(fixture, order)
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

  defp configure_mercado_pago!(fixture) do
    fixture.provider
    |> Ecto.Changeset.change(code: "mercado_pago")
    |> Repo.update!()

    previous = Application.get_env(:clubeira, MercadoPago)

    Application.put_env(:clubeira, MercadoPago,
      accounts: %{
        fixture.merchant_account.provider_account_reference => %{
          access_token: @access_token,
          webhook_secret: @webhook_secret
        }
      },
      req_options: [plug: {Req.Test, MercadoPago}]
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:clubeira, MercadoPago, previous)
      else
        Application.delete_env(:clubeira, MercadoPago)
      end
    end)
  end

  defp refund_order_response(fixture, order, provider_refund_reference) do
    %{
      id: fixture.provider_reference,
      status: "refunded",
      status_detail: "refunded",
      external_reference: "#{fixture.polo.id}_#{order.id}",
      total_amount: Decimal.to_string(order.total_amount),
      currency: order.currency,
      last_updated_date: DateTime.to_iso8601(DateTime.utc_now(:microsecond)),
      transactions: %{
        payments: [
          %{
            id: fixture.provider_reference,
            status: "refunded",
            status_detail: "refunded",
            amount: Decimal.to_string(order.total_amount)
          }
        ],
        refunds: [
          %{
            id: provider_refund_reference,
            transaction_id: fixture.provider_reference,
            amount: Decimal.to_string(order.total_amount),
            status: "processed"
          }
        ]
      }
    }
  end
end
