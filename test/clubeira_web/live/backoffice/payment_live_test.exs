defmodule ClubeiraWeb.Backoffice.PaymentLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Billing
  alias Clubeira.Billing.Chargeback
  alias Clubeira.Billing.Gateways.MercadoPago
  alias Clubeira.BillingFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures
  alias Clubeira.TestDatabaseRole

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
    assert has_element?(detail, "#back-to-finance", "Voltar ao financeiro")
    refute has_element?(detail, "[data-provider-reference]")

    {:ok, default_polo_detail, _html} = live(conn, "/admin/payments/#{payment.id}")

    assert has_element?(default_polo_detail, "#payment-detail-status[data-status='captured']")
  end

  test "formats the payment detail for the negotiated English locale", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {_order, payment} = captured_payment!(fixture, admin_scope)
    session = authenticate!(admin_scope.actor_user_id)
    expected_timestamp = Calendar.strftime(payment.recorded_at, "%Y-%m-%d · %H:%M UTC")

    {:ok, view, _html} =
      conn
      |> put_req_header("accept-language", "en")
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/payments/#{payment.id}?polo=#{fixture.polo_route.slug}")

    assert has_element?(view, "#payment-detail-amount", "BRL 29.90")
    refute has_element?(view, "#payment-detail-amount", "BRL 29,90")
    assert has_element?(view, "#payment-detail-status", "Captured")
    assert has_element?(view, "#payment-detail", expected_timestamp)
    assert has_element?(view, "#back-to-finance", "Back to finance")
  end

  test "an exact detail never resolves a payment from another polo", %{conn: conn} do
    fixture = BillingFixtures.create!()
    other_polo = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    other_admin_scope = grant_admin!(other_polo)
    {_order, other_payment} = captured_payment!(other_polo, other_admin_scope)
    session = authenticate!(admin_scope.actor_user_id)
    expected_path = "/admin?polo=#{fixture.polo_route.slug}#payments-section"
    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(conn, "/admin/payments/#{other_payment.id}?polo=#{fixture.polo_route.slug}")

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(conn, "/admin/payments/not-a-uuid?polo=#{fixture.polo_route.slug}")
  end

  test "an actor without billing-management capability cannot open the detail", %{conn: conn} do
    fixture = BillingFixtures.create!()

    moderator_scope =
      ReviewsFixtures.grant_moderator!(%{
        ids: %{polo: fixture.polo.id},
        scope: fixture.service_scope
      })

    admin_scope = grant_admin!(fixture)
    {_order, payment} = captured_payment!(fixture, admin_scope)
    session = authenticate!(moderator_scope.actor_user_id)
    expected_path = "/admin?polo=#{fixture.polo_route.slug}"
    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(conn, "/admin/payments/#{payment.id}?polo=#{fixture.polo_route.slug}")
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

  test "a revoked browser session cannot refund the payment", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {_order, payment} = captured_payment!(fixture, admin_scope)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/payments/#{payment.id}?polo=#{fixture.polo_route.slug}")

    assert {:ok, account_scope} = Accounts.fetch_scope_by_api_token(session.token)
    assert :ok = Accounts.revoke_session(account_scope)

    view
    |> form("[id^='payment-refund-form-']",
      refund: %{reason: "Sessão revogada não pode movimentar dinheiro"}
    )
    |> render_submit()

    assert_redirect(view, "/admin/login")

    assert {:ok, %{status: "captured", refund: nil}} =
             Billing.get_backoffice_payment(admin_scope, payment.id)
  end

  test "a revoked polo membership cannot refund the payment", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {_order, payment} = captured_payment!(fixture, admin_scope)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/payments/#{payment.id}?polo=#{fixture.polo_route.slug}")

    TestDatabaseRole.as_owner(fn ->
      Repo.query!(
        "UPDATE polo_memberships SET status = 'revoked' WHERE polo_id = $1 AND user_id = $2",
        [Ecto.UUID.dump!(fixture.polo.id), Ecto.UUID.dump!(admin_scope.actor_user_id)]
      )
    end)

    view
    |> form("[id^='payment-refund-form-']",
      refund: %{reason: "Membership revogada não pode movimentar dinheiro"}
    )
    |> render_submit()

    assert_redirect(view, "/admin?polo=#{fixture.polo_route.slug}")

    assert {:ok, %{rows: [["captured", 0]]}} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               {:ok,
                repo.query!(
                  """
                  SELECT payments.status, count(refunds.id)::bigint
                  FROM payments
                  LEFT JOIN refunds
                    ON refunds.payment_id = payments.id
                   AND refunds.polo_id = payments.polo_id
                  WHERE payments.id = $1
                  GROUP BY payments.status
                  """,
                  [Ecto.UUID.dump!(payment.id)]
                )}
             end)
  end

  test "an ambiguous provider failure preserves the exact refund command for retry", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {order, payment} = captured_payment!(fixture, admin_scope)
    session = authenticate!(admin_scope.actor_user_id)
    configure_mercado_pago!(fixture)
    test_process = self()

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/payments/#{payment.id}?polo=#{fixture.polo_route.slug}")

    idempotency_key = input_value(view, "#refund_idempotency_key")
    reason = "Cancelamento confirmado, aguardando resposta do provedor"

    Req.Test.expect(MercadoPago, fn request ->
      [provider_key] = Plug.Conn.get_req_header(request, "x-idempotency-key")
      send(test_process, {:provider_key, provider_key})
      Req.Test.transport_error(request, :timeout)
    end)

    view
    |> form("[id^='payment-refund-form-']", refund: %{reason: reason})
    |> render_submit()

    assert_receive {:provider_key, first_provider_key}
    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#payment-detail-status[data-status='captured']")
    assert input_value(view, "#refund_idempotency_key") == idempotency_key
    assert has_element?(view, "#payment-refund-reason-#{idempotency_key}", reason)

    Req.Test.expect(MercadoPago, fn request ->
      [provider_key] = Plug.Conn.get_req_header(request, "x-idempotency-key")
      send(test_process, {:provider_key, provider_key})

      request
      |> Plug.Conn.put_status(:created)
      |> Req.Test.json(refund_order_response(fixture, order, "refund-live-retry-reference"))
    end)

    view
    |> form("[id^='payment-refund-form-']", refund: %{reason: reason})
    |> render_submit()

    assert_receive {:provider_key, second_provider_key}
    assert second_provider_key == first_provider_key
    assert has_element?(view, "#payment-detail-status[data-status='refunded']")
  end

  test "an unsupported provider preserves the reserved refund command and exposes its lifecycle",
       %{
         conn: conn
       } do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {_order, payment} = captured_payment!(fixture, admin_scope)
    session = authenticate!(admin_scope.actor_user_id)
    path = "/admin/payments/#{payment.id}?polo=#{fixture.polo_route.slug}"

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(path)

    idempotency_key = input_value(view, "#refund_idempotency_key")
    reason = "Reembolso reservado enquanto a configuração do PSP é corrigida"

    view
    |> form("[id^='payment-refund-form-']", refund: %{reason: reason})
    |> render_submit()

    assert has_element?(view, "#flash-error")
    assert input_value(view, "#refund_idempotency_key") == idempotency_key
    assert has_element?(view, "#payment-refund-reason-#{idempotency_key}", reason)

    render_patch(view, path)

    assert has_element?(view, "#payment-refund-summary [data-status='requested']")
    assert has_element?(view, "#payment-refund-unavailable")

    assert {:ok, %{num_rows: 1}} =
             Repo.transact_in_polo(admin_scope, fn repo ->
               {:ok,
                repo.query!(
                  "UPDATE refunds SET status = 'processing' WHERE payment_id = $1",
                  [Ecto.UUID.dump!(payment.id)]
                )}
             end)

    render_patch(view, path)

    assert has_element?(view, "#payment-refund-summary [data-status='processing']")
    assert has_element?(view, "#payment-refund-unavailable")
  end

  test "an idempotency conflict reloads the refund won by another session", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {order, payment} = captured_payment!(fixture, admin_scope)
    session = authenticate!(admin_scope.actor_user_id)
    configure_mercado_pago!(fixture)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/payments/#{payment.id}?polo=#{fixture.polo_route.slug}")

    idempotency_key = input_value(view, "#refund_idempotency_key")

    Req.Test.expect(MercadoPago, fn request ->
      request
      |> Plug.Conn.put_status(:created)
      |> Req.Test.json(refund_order_response(fixture, order, "refund-live-winner-reference"))
    end)

    assert {:ok, _refund} =
             Billing.refund_payment(admin_scope, payment.id, %{
               idempotency_key: idempotency_key,
               reason: "Outra sessão venceu a operação financeira"
             })

    view
    |> form("[id^='payment-refund-form-']",
      refund: %{reason: "Payload diferente para uma chave já utilizada"}
    )
    |> render_submit()

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#payment-detail-status[data-status='refunded']")
    assert has_element?(view, "#payment-refund-summary [data-status='succeeded']")
    assert has_element?(view, "#payment-refund-unavailable")
  end

  test "invalid and malformed refund requests stay at the LiveView boundary", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {_order, payment} = captured_payment!(fixture, admin_scope)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/payments/#{payment.id}?polo=#{fixture.polo_route.slug}")

    view
    |> form("[id^='payment-refund-form-']", refund: %{reason: "  "})
    |> render_submit()

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#payment-refund-reason-field > div > p")
    assert has_element?(view, "#payment-detail-status[data-status='captured']")

    render_submit(view, "refund_payment", %{})
    assert has_element?(view, "#flash-error")

    render_submit(view, "refund_payment", %{"refund" => "not-a-map"})
    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#payment-detail-status[data-status='captured']")

    assert {:ok, %{refund: nil}} = Billing.get_backoffice_payment(admin_scope, payment.id)
  end

  test "a stale refund action reloads the current payment state", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {_order, payment} = captured_payment!(fixture, admin_scope)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/payments/#{payment.id}?polo=#{fixture.polo_route.slug}")

    assert {:ok, %{num_rows: 1}} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               result =
                 repo.query!(
                   """
                   UPDATE payments
                   SET status = 'charged_back',
                       charged_back_at = statement_timestamp()
                   WHERE id = $1
                   """,
                   [Ecto.UUID.dump!(payment.id)]
                 )

               {:ok, result}
             end)

    view
    |> form("[id^='payment-refund-form-']",
      refund: %{reason: "Tela antiga não pode reembolsar chargeback"}
    )
    |> render_submit()

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#payment-detail-status[data-status='charged_back']")
    assert has_element?(view, "#payment-refund-unavailable")
  end

  test "tampered payment and amount fields never retarget a refund", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {order, payment} = captured_payment!(fixture, admin_scope)
    session = authenticate!(admin_scope.actor_user_id)
    configure_mercado_pago!(fixture)

    Req.Test.expect(MercadoPago, fn request ->
      request
      |> Plug.Conn.put_status(:created)
      |> Req.Test.json(refund_order_response(fixture, order, "refund-live-tampered-reference"))
    end)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/payments/#{payment.id}?polo=#{fixture.polo_route.slug}")

    render_submit(view, "refund_payment", %{
      "refund" => %{
        "reason" => "Campos financeiros adulterados devem ser ignorados",
        "idempotency_key" => input_value(view, "#refund_idempotency_key"),
        "payment_id" => Ecto.UUID.generate(),
        "amount" => "0.01",
        "currency" => "USD"
      }
    })

    assert has_element?(view, "#payment-detail-status[data-status='refunded']")
    assert has_element?(view, "#payment-refund-summary", "BRL 29,90")

    assert {:ok, %{id: payment_id, amount: amount, status: "refunded"}} =
             Billing.get_backoffice_payment(admin_scope, payment.id)

    assert payment_id == payment.id
    assert Decimal.equal?(amount, payment.amount)
  end

  test "a definitive provider rejection exposes the failed attempt and a fresh command", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {_order, payment} = captured_payment!(fixture, admin_scope)
    session = authenticate!(admin_scope.actor_user_id)
    configure_mercado_pago!(fixture)

    Req.Test.expect(MercadoPago, fn request ->
      request
      |> Plug.Conn.put_status(:bad_request)
      |> Req.Test.json(%{message: "refund_not_available"})
    end)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/payments/#{payment.id}?polo=#{fixture.polo_route.slug}")

    rejected_key = input_value(view, "#refund_idempotency_key")

    view
    |> form("[id^='payment-refund-form-']",
      refund: %{reason: "Tentativa rejeitada de forma definitiva pelo provedor"}
    )
    |> render_submit()

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#payment-detail-status[data-status='captured']")
    assert has_element?(view, "#payment-refund-summary [data-status='failed']")
    assert has_element?(view, "[id^='payment-refund-form-']")
    refute input_value(view, "#refund_idempotency_key") == rejected_key
  end

  test "a terminal payment rejects manually pushed refund events", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {order, payment} = captured_payment!(fixture, admin_scope)
    session = authenticate!(admin_scope.actor_user_id)
    configure_mercado_pago!(fixture)

    Req.Test.expect(MercadoPago, fn request ->
      request
      |> Plug.Conn.put_status(:created)
      |> Req.Test.json(refund_order_response(fixture, order, "refund-live-terminal-reference"))
    end)

    assert {:ok, refund} =
             Billing.refund_payment(admin_scope, payment.id, %{
               idempotency_key: "payment-live-terminal-refund",
               reason: "Reembolso concluído antes de abrir o painel"
             })

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/payments/#{payment.id}?polo=#{fixture.polo_route.slug}")

    assert has_element?(view, "#payment-refund-unavailable")

    render_submit(view, "refund_payment", %{
      "refund" => %{
        "reason" => "Evento manual não pode repetir pagamento terminal",
        "idempotency_key" => "payment-live-terminal-event"
      }
    })

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#payment-detail-status[data-status='refunded']")
    assert has_element?(view, "#payment-refund-summary [data-status='succeeded']")

    assert {:ok, %{refund: %{id: refund_id}}} =
             Billing.get_backoffice_payment(admin_scope, payment.id)

    assert refund_id == refund.id
  end

  test "the detail exposes a safe chargeback summary and no refund action", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {_order, payment} = captured_payment!(fixture, admin_scope)
    session = authenticate!(admin_scope.actor_user_id)
    opened_at = DateTime.utc_now(:microsecond)

    assert {:ok, chargeback} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               repo.query!(
                 """
                 UPDATE payments
                 SET status = 'charged_back', charged_back_at = $2
                 WHERE id = $1
                 """,
                 [Ecto.UUID.dump!(payment.id), opened_at]
               )

               chargeback =
                 repo.insert!(%Chargeback{
                   polo_id: fixture.polo.id,
                   payment_id: payment.id,
                   provider_reference: "private-chargeback-reference",
                   amount: payment.amount,
                   reason_code: "private-provider-reason",
                   status: "lost",
                   opened_at: opened_at,
                   closed_at: opened_at,
                   inserted_at: opened_at,
                   updated_at: opened_at
                 })

               {:ok, chargeback}
             end)

    {:ok, view, html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/payments/#{payment.id}?polo=#{fixture.polo_route.slug}")

    assert has_element?(view, "#payment-detail-status[data-status='charged_back']")

    assert has_element?(
             view,
             "#payment-chargeback-summary [data-status='#{chargeback.status}']"
           )

    assert has_element?(view, "#payment-chargeback-summary", "BRL 29,90")
    assert has_element?(view, "#payment-refund-unavailable")
    refute html =~ "private-chargeback-reference"
    refute html =~ "private-provider-reason"
  end

  test "the detail renders every persisted payment and order status" do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {order, payment} = captured_payment!(fixture, admin_scope)
    session = authenticate!(admin_scope.actor_user_id)
    path = "/admin/payments/#{payment.id}?polo=#{fixture.polo_route.slug}"

    states = [
      {"authorized", "pending"},
      {"authorized", "awaiting_payment"},
      {"failed", "cancelled"},
      {"cancelled", "expired"},
      {"refunded", "refunded"},
      {"charged_back", "charged_back"}
    ]

    Enum.each(states, fn {payment_status, order_status} ->
      set_payment_states!(admin_scope, payment, order, payment_status, order_status)

      {:ok, view, _html} =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("accept-language", "en")
        |> init_test_session(%{
          "backoffice_session_token" => session.token,
          "locale" => "en"
        })
        |> live(path)

      assert has_element?(view, "#payment-detail-status[data-status='#{payment_status}']")

      assert has_element?(
               view,
               "#payment-detail-order-status[data-status='#{order_status}']"
             )

      if order_status == "pending" do
        assert has_element?(view, "#payment-detail-placed-at", "Not available")
        assert has_element?(view, "#payment-detail-captured-at", "Not available")
      end
    end)
  end

  test "tampered and malformed polo selection never retargets the payment", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {_order, payment} = captured_payment!(fixture, admin_scope)
    session = authenticate!(admin_scope.actor_user_id)
    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})
    expected_path = "/admin?polo=#{fixture.polo_route.slug}#payments-section"

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(conn, "/admin/payments/#{payment.id}?polo=not-authorized")

    {:ok, switch_view, _html} =
      live(conn, "/admin/payments/#{payment.id}?polo=#{fixture.polo_route.slug}")

    render_change(switch_view, "change_polo", %{
      "context" => %{"polo" => fixture.polo_route.slug}
    })

    assert_redirect(switch_view, expected_path)

    {:ok, unknown_polo_view, _html} =
      live(conn, "/admin/payments/#{payment.id}?polo=#{fixture.polo_route.slug}")

    render_change(unknown_polo_view, "change_polo", %{
      "context" => %{"polo" => "not-authorized"}
    })

    assert_redirect(unknown_polo_view, expected_path)

    {:ok, view, _html} =
      live(conn, "/admin/payments/#{payment.id}?polo=#{fixture.polo_route.slug}")

    render_change(view, "change_polo", %{})

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#payment-detail-status[data-status='captured']")
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

  defp set_payment_states!(scope, payment, order, payment_status, order_status) do
    assert {:ok, :updated} =
             Repo.transact_in_polo(scope, fn repo ->
               assert %{num_rows: 1} =
                        repo.query!(
                          """
                          UPDATE payments
                          SET status = $2,
                              captured_at = CASE
                                WHEN $2 IN ('captured', 'refunded', 'charged_back')
                                  THEN COALESCE(captured_at, statement_timestamp())
                                ELSE NULL
                              END,
                              failed_at = CASE
                                WHEN $2 = 'failed' THEN statement_timestamp()
                                ELSE NULL
                              END,
                              refunded_at = CASE
                                WHEN $2 = 'refunded' THEN statement_timestamp()
                                ELSE NULL
                              END,
                              charged_back_at = CASE
                                WHEN $2 = 'charged_back' THEN statement_timestamp()
                                ELSE NULL
                              END
                          WHERE id = $1
                          """,
                          [Ecto.UUID.dump!(payment.id), payment_status]
                        )

               assert %{num_rows: 1} =
                        repo.query!(
                          """
                          UPDATE orders
                          SET status = $2,
                              placed_at = CASE
                                WHEN $2 = 'pending' THEN NULL
                                ELSE COALESCE(placed_at, statement_timestamp())
                              END,
                              updated_at = statement_timestamp()
                          WHERE id = $1
                          """,
                          [Ecto.UUID.dump!(order.id), order_status]
                        )

               {:ok, :updated}
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

  defp input_value(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("value")
    |> List.first()
  end
end
