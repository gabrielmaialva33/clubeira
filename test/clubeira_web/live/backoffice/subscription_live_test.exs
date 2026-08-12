defmodule ClubeiraWeb.Backoffice.SubscriptionLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Billing
  alias Clubeira.BillingFixtures
  alias Clubeira.Idempotency
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures
  alias Clubeira.Subscriptions
  alias Clubeira.TestDatabaseRole

  @password "uma-senha-forte-para-o-detalhe-web-de-assinatura"

  test "a billing admin opens one exact subscription from the inventory", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {order, contract} = captured_subscription!(fixture)
    session = authenticate!(admin_scope.actor_user_id)
    detail_path = "/admin/subscriptions/#{contract.id}?polo=#{fixture.polo_route.slug}"

    conn =
      conn
      |> put_req_header("accept-language", "en")
      |> init_test_session(%{"backoffice_session_token" => session.token})

    {:ok, inventory, _html} =
      live(conn, "/admin/subscriptions?polo=#{fixture.polo_route.slug}")

    assert has_element?(
             inventory,
             "#subscription-link-#{contract.id}[href='#{detail_path}']"
           )

    {:ok, detail, _html} = live(conn, detail_path)

    assert has_element?(detail, "#subscription-detail")
    assert has_element?(detail, "#subscription-detail-status[data-status='active']")
    assert has_element?(detail, "#subscription-detail-order", order.order_number)
    assert has_element?(detail, "#subscription-detail-order-status[data-status='paid']")
    assert has_element?(detail, "#subscription-detail-offering", fixture.offering_version.name)

    {:ok, default_polo_detail, _html} = live(conn, "/admin/subscriptions/#{contract.id}")

    assert has_element?(default_polo_detail, "#subscription-detail-status[data-status='active']")
  end

  test "an exact detail never resolves a contract from another polo", %{conn: conn} do
    fixture = BillingFixtures.create!()
    other_polo = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {_order, other_contract} = captured_subscription!(other_polo)
    session = authenticate!(admin_scope.actor_user_id)
    expected_path = "/admin/subscriptions?polo=#{fixture.polo_route.slug}"
    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(
               conn,
               "/admin/subscriptions/#{other_contract.id}?polo=#{fixture.polo_route.slug}"
             )

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(conn, "/admin/subscriptions/not-a-uuid?polo=#{fixture.polo_route.slug}")
  end

  test "an actor without billing-management capability cannot open the detail", %{conn: conn} do
    fixture = BillingFixtures.create!()

    moderator_scope =
      ReviewsFixtures.grant_moderator!(%{
        ids: %{polo: fixture.polo.id},
        scope: fixture.service_scope
      })

    {_order, contract} = captured_subscription!(fixture)
    session = authenticate!(moderator_scope.actor_user_id)
    expected_path = "/admin?polo=#{fixture.polo_route.slug}"
    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(conn, "/admin/subscriptions/#{contract.id}?polo=#{fixture.polo_route.slug}")
  end

  test "a billing admin suspends and reactivates the exact subscription", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {_order, contract} = captured_subscription!(fixture)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/subscriptions/#{contract.id}?polo=#{fixture.polo_route.slug}")

    assert has_element?(view, "[id^='subscription-lifecycle-form-']")
    assert has_element?(view, "#lifecycle_action option[value='suspend'][selected]")

    initial_idempotency_key = input_value(view, "#lifecycle_idempotency_key")

    assert has_element?(
             view,
             "#subscription-lifecycle-reason-#{initial_idempotency_key}"
           )

    view
    |> form("[id^='subscription-lifecycle-form-']",
      lifecycle: %{
        action: "suspend",
        reason: "Pausa operacional confirmada pelo financeiro"
      }
    )
    |> render_submit()

    assert has_element?(view, "#subscription-detail-status[data-status='suspended']")
    assert has_element?(view, "#lifecycle_action option[value='reactivate'][selected]")

    suspended_idempotency_key = input_value(view, "#lifecycle_idempotency_key")

    refute suspended_idempotency_key == initial_idempotency_key

    refute has_element?(
             view,
             "#subscription-lifecycle-reason-#{initial_idempotency_key}"
           )

    assert has_element?(
             view,
             "#subscription-lifecycle-reason-#{suspended_idempotency_key}"
           )

    view
    |> form("[id^='subscription-lifecycle-form-']",
      lifecycle: %{
        action: "reactivate",
        reason: "Pendência financeira regularizada"
      }
    )
    |> render_submit()

    assert has_element?(view, "#subscription-detail-status[data-status='active']")
    assert has_element?(view, "#lifecycle_action option[value='suspend'][selected]")
  end

  test "a revoked browser session cannot mutate the subscription", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {_order, contract} = captured_subscription!(fixture)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/subscriptions/#{contract.id}?polo=#{fixture.polo_route.slug}")

    assert {:ok, account_scope} = Accounts.fetch_scope_by_api_token(session.token)
    assert :ok = Accounts.revoke_session(account_scope)

    view
    |> form("[id^='subscription-lifecycle-form-']",
      lifecycle: %{
        action: "suspend",
        reason: "A sessão revogada não pode suspender contratos"
      }
    )
    |> render_submit()

    assert_redirect(view, "/admin/login")

    assert {:ok, %{status: "active"}} =
             Subscriptions.get_backoffice_subscription(admin_scope, contract.id)
  end

  test "a revoked polo membership cannot mutate the subscription", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {_order, contract} = captured_subscription!(fixture)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/subscriptions/#{contract.id}?polo=#{fixture.polo_route.slug}")

    detail_path =
      "/admin/subscriptions/#{contract.id}?polo=#{fixture.polo_route.slug}"

    {:ok, reload_view, _html} =
      Phoenix.ConnTest.build_conn()
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(detail_path)

    TestDatabaseRole.as_owner(fn ->
      Repo.query!(
        "UPDATE polo_memberships SET status = 'revoked' WHERE polo_id = $1 AND user_id = $2",
        [Ecto.UUID.dump!(fixture.polo.id), Ecto.UUID.dump!(admin_scope.actor_user_id)]
      )
    end)

    render_patch(reload_view, detail_path)
    assert_redirect(reload_view, "/admin?polo=#{fixture.polo_route.slug}")

    view
    |> form("[id^='subscription-lifecycle-form-']",
      lifecycle: %{
        action: "suspend",
        reason: "A membership revogada não pode suspender contratos"
      }
    )
    |> render_submit()

    assert_redirect(view, "/admin?polo=#{fixture.polo_route.slug}")

    assert {:ok, %{rows: [["active"]]}} =
             Repo.transact_in_polo(fixture.service_scope, fn repo ->
               {:ok,
                repo.query!("SELECT status FROM access_contracts WHERE id = $1", [
                  Ecto.UUID.dump!(contract.id)
                ])}
             end)
  end

  test "an idempotency conflict reloads the state won by another session", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {_order, contract} = captured_subscription!(fixture)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/subscriptions/#{contract.id}?polo=#{fixture.polo_route.slug}")

    idempotency_key = input_value(view, "#lifecycle_idempotency_key")

    assert {:ok, %{"status" => "suspended"}} =
             Subscriptions.transition_contract(admin_scope, contract.id, %{
               action: "suspend",
               reason: "Outra sessão venceu esta operação",
               idempotency_key: idempotency_key
             })

    view
    |> form("[id^='subscription-lifecycle-form-']",
      lifecycle: %{
        action: "suspend",
        reason: "Payload diferente para a chave já utilizada"
      }
    )
    |> render_submit()

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#subscription-detail-status[data-status='suspended']")
    assert has_element?(view, "#lifecycle_action option[value='reactivate'][selected]")
    refute input_value(view, "#lifecycle_idempotency_key") == idempotency_key
  end

  test "an in-progress lifecycle request preserves the exact command for retry", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {_order, contract} = captured_subscription!(fixture)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/subscriptions/#{contract.id}?polo=#{fixture.polo_route.slug}")

    idempotency_key = input_value(view, "#lifecycle_idempotency_key")
    reason = "Operação ainda reservada por outro worker"

    request_hash =
      Idempotency.fingerprint({
        1,
        admin_scope.polo_id,
        admin_scope.actor_user_id,
        contract.id,
        "suspend",
        reason
      })

    assert {:ok, :reserved} =
             Repo.transact_in_polo(admin_scope, fn repo ->
               %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")

               assert {:new, _reservation_id} =
                        Idempotency.reserve(
                          repo,
                          admin_scope,
                          "subscriptions.transition_contract",
                          idempotency_key,
                          request_hash,
                          now
                        )

               {:ok, :reserved}
             end)

    view
    |> form("[id^='subscription-lifecycle-form-']",
      lifecycle: %{action: "suspend", reason: reason}
    )
    |> render_submit()

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#subscription-detail-status[data-status='active']")
    assert input_value(view, "#lifecycle_idempotency_key") == idempotency_key

    assert has_element?(
             view,
             "#subscription-lifecycle-reason-#{idempotency_key}",
             reason
           )
  end

  test "a stale lifecycle action reloads the current contract state", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {_order, contract} = captured_subscription!(fixture)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/subscriptions/#{contract.id}?polo=#{fixture.polo_route.slug}")

    assert {:ok, %{"status" => "suspended"}} =
             Subscriptions.transition_contract(admin_scope, contract.id, %{
               action: "suspend",
               reason: "Suspensão decidida em outra sessão administrativa",
               idempotency_key: "subscription-live-stale-winner"
             })

    view
    |> form("[id^='subscription-lifecycle-form-']",
      lifecycle: %{
        action: "suspend",
        reason: "Tentativa baseada no estado anterior"
      }
    )
    |> render_submit()

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#subscription-detail-status[data-status='suspended']")
    assert has_element?(view, "#lifecycle_action option[value='reactivate'][selected]")
  end

  test "invalid, malformed and unavailable lifecycle requests stay at the boundary", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {_order, contract} = captured_subscription!(fixture)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/subscriptions/#{contract.id}?polo=#{fixture.polo_route.slug}")

    view
    |> form("[id^='subscription-lifecycle-form-']",
      lifecycle: %{action: "suspend", reason: "  "}
    )
    |> render_submit()

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#subscription-lifecycle-reason-field > div > p")
    assert has_element?(view, "#subscription-detail-status[data-status='active']")

    render_submit(view, "transition_contract", %{})

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#subscription-detail-status[data-status='active']")

    TestDatabaseRole.as_owner(fn ->
      Repo.query!("UPDATE polos SET status = 'suspended' WHERE id = $1", [
        Ecto.UUID.dump!(fixture.polo.id)
      ])
    end)

    view
    |> form("[id^='subscription-lifecycle-form-']",
      lifecycle: %{
        action: "suspend",
        reason: "Polo indisponível não pode alterar o contrato"
      }
    )
    |> render_submit()

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#subscription-detail-status[data-status='active']")
  end

  test "a terminal subscription rejects manually pushed lifecycle events", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {_order, contract} = captured_subscription!(fixture)
    session = authenticate!(admin_scope.actor_user_id)

    assert {:ok, %{num_rows: 1}} =
             Repo.transact_in_polo(admin_scope, fn repo ->
               result =
                 repo.query!(
                   """
                   UPDATE access_contracts
                   SET status = 'cancelled',
                       cancelled_at = statement_timestamp(),
                       updated_at = statement_timestamp()
                   WHERE id = $1
                   """,
                   [Ecto.UUID.dump!(contract.id)]
                 )

               {:ok, result}
             end)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/subscriptions/#{contract.id}?polo=#{fixture.polo_route.slug}")

    assert has_element?(view, "#subscription-lifecycle-unavailable")

    render_submit(view, "transition_contract", %{
      "lifecycle" => %{
        "action" => "reactivate",
        "reason" => "Evento manual não deve operar contrato terminal",
        "idempotency_key" => "subscription-live-terminal-event"
      }
    })

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#subscription-detail-status[data-status='cancelled']")
  end

  test "the detail renders every persisted contract and order status" do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {order, contract} = captured_subscription!(fixture)
    session = authenticate!(admin_scope.actor_user_id)
    path = "/admin/subscriptions/#{contract.id}?polo=#{fixture.polo_route.slug}"

    states = [
      {"pending", "pending"},
      {"past_due", "awaiting_payment"},
      {"expired", "expired"},
      {"cancelled", "cancelled"},
      {"active", "refunded"},
      {"active", "charged_back"}
    ]

    Enum.each(states, fn {contract_status, order_status} ->
      set_subscription_states!(admin_scope, contract, order, contract_status, order_status)

      {:ok, view, _html} =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("accept-language", "en")
        |> init_test_session(%{
          "backoffice_session_token" => session.token,
          "locale" => "en"
        })
        |> live(path)

      assert has_element?(
               view,
               "#subscription-detail-status[data-status='#{contract_status}']"
             )

      assert has_element?(
               view,
               "#subscription-detail-order-status[data-status='#{order_status}']"
             )

      if contract_status == "pending" do
        assert has_element?(view, "#subscription-detail-placed-at", "Not available")
        assert has_element?(view, "#subscription-detail-activated-at", "Not available")
      end
    end)
  end

  test "tampered and malformed polo selection never retargets the contract", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    {_order, contract} = captured_subscription!(fixture)
    session = authenticate!(admin_scope.actor_user_id)
    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})
    expected_path = "/admin/subscriptions?polo=#{fixture.polo_route.slug}"

    assert {:error, {:redirect, %{to: ^expected_path}}} =
             live(conn, "/admin/subscriptions/#{contract.id}?polo=not-authorized")

    {:ok, switch_view, _html} =
      live(conn, "/admin/subscriptions/#{contract.id}?polo=#{fixture.polo_route.slug}")

    render_change(switch_view, "change_polo", %{
      "context" => %{"polo" => fixture.polo_route.slug}
    })

    assert_redirect(switch_view, expected_path)

    {:ok, unknown_polo_view, _html} =
      live(conn, "/admin/subscriptions/#{contract.id}?polo=#{fixture.polo_route.slug}")

    render_change(unknown_polo_view, "change_polo", %{
      "context" => %{"polo" => "not-authorized"}
    })

    assert_redirect(unknown_polo_view, expected_path)

    {:ok, view, _html} =
      live(conn, "/admin/subscriptions/#{contract.id}?polo=#{fixture.polo_route.slug}")

    render_change(view, "change_polo", %{})

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#subscription-detail-status[data-status='active']")
  end

  defp grant_admin!(fixture) do
    ReviewsFixtures.grant_moderator!(
      %{ids: %{polo: fixture.polo.id}, scope: fixture.service_scope},
      role_key: "admin"
    )
  end

  defp captured_subscription!(fixture) do
    assert {:ok, order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture, %{
                 idempotency_key: "subscription-live-checkout-#{Ecto.UUID.generate()}"
               })
             )

    assert {:ok, contract} =
             Billing.settle_payment(
               fixture.service_scope,
               BillingFixtures.settled_payment(fixture, order)
             )

    {order, contract}
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session
  end

  defp set_subscription_states!(scope, contract, order, contract_status, order_status) do
    assert {:ok, :updated} =
             Repo.transact_in_polo(scope, fn repo ->
               assert %{num_rows: 1} =
                        repo.query!(
                          """
                          UPDATE access_contracts
                          SET status = $2,
                              activated_at = CASE
                                WHEN $2 = 'pending' THEN NULL
                                ELSE COALESCE(activated_at, statement_timestamp())
                              END,
                              cancelled_at = CASE
                                WHEN $2 = 'cancelled' THEN statement_timestamp()
                                ELSE NULL
                              END,
                              updated_at = statement_timestamp()
                          WHERE id = $1
                          """,
                          [Ecto.UUID.dump!(contract.id), contract_status]
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

  defp input_value(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("value")
    |> List.first()
  end
end
