defmodule ClubeiraWeb.Backoffice.PlatformBillingLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Billing.Gateways.MercadoPago
  alias Clubeira.BillingFixtures
  alias Clubeira.Factory
  alias Clubeira.Platform.Plan
  alias Clubeira.Platform.PlanVersion
  alias Clubeira.Platform.PoloSubscription
  alias Clubeira.Platform.Price
  alias Clubeira.PlatformBilling
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures
  alias Clubeira.TestDatabaseRole

  @password "uma-senha-forte-para-billing-saas-web"
  @access_token "platform-billing-live-access-token"
  @back_url "https://clubeira.test/platform-billing/return"

  test "shows the current SaaS billing view for the selected polo only", %{conn: conn} do
    fixture = BillingFixtures.create!()
    other_fixture = BillingFixtures.create!()
    admin_scope = grant_polo_admin!(fixture)
    _other_admin = grant_polo_admin!(other_fixture)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/platform-billing?polo=#{fixture.polo_route.slug}")

    assert has_element?(view, "#platform-billing-page")
    assert has_element?(view, "#platform-billing-no-subscription")
    assert has_element?(view, "#backoffice-nav-platform-billing[aria-current='page']")
  end

  test "offers only current tenant-authorized prices without exposing UUID text inputs", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    admin_scope = grant_polo_admin!(fixture)
    option = insert_option!()
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/platform-billing?polo=#{fixture.polo_route.slug}")

    assert has_element?(
             view,
             "#platform-subscription-price-id option[value='#{option.price.id}']"
           )

    refute has_element?(view, "#platform-subscription-price-id[type='text']")
    assert has_element?(view, "#platform-subscription-start-form")
  end

  test "starts the selected SaaS subscription and refreshes the current billing view", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    admin_scope = grant_polo_admin!(fixture)
    option = insert_option!()
    configure_platform_gateway!(fixture)
    session = authenticate!(admin_scope.actor_user_id)
    provider_reference = "PREAPPROVAL-#{uuid7()}"

    Req.Test.expect(MercadoPago, fn request ->
      assert request.method == "POST"
      assert request.request_path == "/preapproval"
      assert Plug.Conn.get_req_header(request, "authorization") == ["Bearer #{@access_token}"]
      assert {:ok, body, request} = Plug.Conn.read_body(request)
      payload = Jason.decode!(body)

      Req.Test.json(request, %{
        id: provider_reference,
        external_reference: payload["external_reference"],
        status: "authorized",
        auto_recurring: %{
          frequency: 1,
          frequency_type: "months",
          transaction_amount: "399.90",
          currency_id: "BRL"
        }
      })
    end)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/platform-billing?polo=#{fixture.polo_route.slug}")

    view
    |> form("#platform-subscription-start-form",
      platform_subscription: %{
        platform_price_id: option.price.id
      }
    )
    |> render_submit()

    assert has_element?(view, "#platform-billing-subscription")
    refute has_element?(view, "#platform-subscription-start-form")
    refute has_element?(view, "#platform-billing-no-subscription")
  end

  test "rejects a forged SaaS price outside the rendered subscription options", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_polo_admin!(fixture)
    _option = insert_option!()
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/platform-billing?polo=#{fixture.polo_route.slug}")

    render_hook(view, "start_platform_subscription", %{
      "platform_subscription" => %{
        "platform_price_id" => uuid7(),
        "idempotency_key" => "forged-platform-subscription"
      }
    })

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#platform-billing-no-subscription")
    assert {:ok, %{subscription: nil}} = PlatformBilling.get_billing(admin_scope)
  end

  test "keeps the SaaS subscription form when its server command is invalid", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_polo_admin!(fixture)
    option = insert_option!()
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/platform-billing?polo=#{fixture.polo_route.slug}")

    render_hook(view, "start_platform_subscription", %{
      "platform_subscription" => %{
        "platform_price_id" => option.price.id,
        "idempotency_key" => "short"
      }
    })

    assert has_element?(view, "#platform-subscription-start-form")
    assert has_element?(view, "#flash-error")
    assert {:ok, %{subscription: nil}} = PlatformBilling.get_billing(admin_scope)
  end

  test "redirects to the authenticated PSP checkout returned for a pending subscription", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    admin_scope = grant_polo_admin!(fixture)
    option = insert_option!()
    configure_platform_gateway!(fixture)
    session = authenticate!(admin_scope.actor_user_id)
    provider_reference = "PREAPPROVAL-#{uuid7()}"
    redirect_url = "https://www.mercadopago.com.br/subscriptions/checkout/#{uuid7()}"

    Req.Test.expect(MercadoPago, fn request ->
      assert {:ok, body, request} = Plug.Conn.read_body(request)
      payload = Jason.decode!(body)

      Req.Test.json(request, %{
        id: provider_reference,
        external_reference: payload["external_reference"],
        status: "pending",
        init_point: redirect_url,
        auto_recurring: %{
          frequency: 1,
          frequency_type: "months",
          transaction_amount: "399.90",
          currency_id: "BRL"
        }
      })
    end)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/platform-billing?polo=#{fixture.polo_route.slug}")

    view
    |> form("#platform-subscription-start-form",
      platform_subscription: %{platform_price_id: option.price.id}
    )
    |> render_submit()

    assert_redirect(view, redirect_url)

    assert {:ok, %{subscription: %{status: "pending"}}} =
             PlatformBilling.get_billing(admin_scope)

    {:ok, pending_view, _html} =
      conn
      |> put_req_header("accept-language", "en")
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/platform-billing?polo=#{fixture.polo_route.slug}")

    assert has_element?(pending_view, "#platform-billing-subscription", "Pending")
  end

  test "keeps the exact start form retryable when the PSP response is invalid", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_polo_admin!(fixture)
    option = insert_option!()
    configure_platform_gateway!(fixture)
    session = authenticate!(admin_scope.actor_user_id)

    Req.Test.expect(MercadoPago, fn request ->
      Req.Test.json(request, %{"id" => "PREAPPROVAL-#{uuid7()}", "status" => "authorized"})
    end)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/platform-billing?polo=#{fixture.polo_route.slug}")

    view
    |> form("#platform-subscription-start-form",
      platform_subscription: %{platform_price_id: option.price.id}
    )
    |> render_submit()

    assert has_element?(view, "#platform-subscription-start-form")
    assert has_element?(view, "#flash-error")

    assert {:ok, %{subscription: %{status: "pending"}}} =
             PlatformBilling.get_billing(admin_scope)
  end

  test "a revoked browser session cannot start a SaaS subscription", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_polo_admin!(fixture)
    option = insert_option!()
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/platform-billing?polo=#{fixture.polo_route.slug}")

    assert {:ok, account_scope} = Accounts.fetch_scope_by_api_token(session.token)
    assert :ok = Accounts.revoke_session(account_scope)

    view
    |> form("#platform-subscription-start-form",
      platform_subscription: %{platform_price_id: option.price.id}
    )
    |> render_submit()

    assert_redirect(view, "/admin/login")
    assert {:ok, %{subscription: nil}} = PlatformBilling.get_billing(admin_scope)
  end

  test "redirects an operator without billing-management capability", %{conn: conn} do
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
             live(conn, "/admin/platform-billing?polo=#{fixture.polo_route.slug}")
  end

  test "redirects safely when the selected polo becomes unavailable", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_polo_admin!(fixture)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/platform-billing?polo=#{fixture.polo_route.slug}")

    TestDatabaseRole.as_owner(fn ->
      Repo.query!("UPDATE polos SET status = 'suspended' WHERE id = $1", [
        Ecto.UUID.dump!(fixture.polo.id)
      ])
    end)

    render_change(view, "change_polo", %{"context" => %{"polo" => fixture.polo_route.slug}})

    assert_redirect(view, "/admin")
  end

  test "keeps the billing boundary alive for unknown polos and malformed events", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_polo_admin!(fixture)
    _option = insert_option!()
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/platform-billing?polo=#{fixture.polo_route.slug}")

    render_change(view, "change_polo", %{"context" => %{"polo" => "not-authorized"}})
    assert_patch(view, "/admin/platform-billing?polo=#{fixture.polo_route.slug}")

    render_change(view, "change_polo", %{})
    assert has_element?(view, "#flash-error")

    render_hook(view, "start_platform_subscription", %{})
    assert has_element?(view, "#flash-error")

    render_hook(view, "start_platform_subscription", %{
      "platform_subscription" => %{"platform_price_id" => 123}
    })

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#platform-subscription-start-form")
  end

  test "keeps a valid command retryable when the PSP is not configured", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_polo_admin!(fixture)
    option = insert_option!()
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/platform-billing?polo=#{fixture.polo_route.slug}")

    view
    |> form("#platform-subscription-start-form",
      platform_subscription: %{platform_price_id: option.price.id}
    )
    |> render_submit()

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#platform-subscription-start-form")

    assert {:ok, %{subscription: nil}} = PlatformBilling.get_billing(admin_scope)
  end

  test "reloads subscription options when the rendered price expires", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_polo_admin!(fixture)
    option = insert_option!()
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/platform-billing?polo=#{fixture.polo_route.slug}")

    now = DateTime.utc_now(:microsecond)

    option.price
    |> Ecto.Changeset.change(
      valid_during: Factory.tstz_range(DateTime.add(now, -3_600), DateTime.add(now, -60))
    )
    |> Repo.update!()

    render_hook(view, "start_platform_subscription", %{
      "platform_subscription" => %{
        "platform_price_id" => option.price.id,
        "idempotency_key" => "expired-platform-price-web"
      }
    })

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#platform-billing-no-options")
    refute has_element?(view, "#platform-subscription-start-form")
    assert {:ok, %{subscription: nil}} = PlatformBilling.get_billing(admin_scope)
  end

  test "reloads billing after another browser starts the current subscription", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_polo_admin!(fixture)
    option = insert_option!()
    configure_platform_gateway!(fixture)
    session = authenticate!(admin_scope.actor_user_id)

    Req.Test.expect(MercadoPago, fn request ->
      assert {:ok, body, request} = Plug.Conn.read_body(request)
      payload = Jason.decode!(body)

      Req.Test.json(request, %{
        id: "PREAPPROVAL-#{uuid7()}",
        external_reference: payload["external_reference"],
        status: "authorized",
        auto_recurring: %{
          frequency: 1,
          frequency_type: "months",
          transaction_amount: "399.90",
          currency_id: "BRL"
        }
      })
    end)

    session_conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    {:ok, first_view, _html} =
      live(session_conn, "/admin/platform-billing?polo=#{fixture.polo_route.slug}")

    {:ok, stale_view, _html} =
      live(session_conn, "/admin/platform-billing?polo=#{fixture.polo_route.slug}")

    first_view
    |> form("#platform-subscription-start-form",
      platform_subscription: %{platform_price_id: option.price.id}
    )
    |> render_submit()

    assert {:ok, %{subscription: %{status: "active"}}} =
             PlatformBilling.get_billing(admin_scope)

    stale_view
    |> form("#platform-subscription-start-form",
      platform_subscription: %{platform_price_id: option.price.id}
    )
    |> render_submit()

    assert {:ok, %{subscription: %{status: "active"}}} =
             PlatformBilling.get_billing(admin_scope)

    assert has_element?(stale_view, "#flash-error")
    assert has_element?(stale_view, "#platform-billing-subscription")
    refute has_element?(stale_view, "#platform-subscription-start-form")
  end

  test "reauthorizes the billing role before contacting the PSP", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_polo_admin!(fixture)
    option = insert_option!()
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/platform-billing?polo=#{fixture.polo_route.slug}")

    revoke_membership!(fixture.polo.id, admin_scope.actor_user_id)

    render_hook(view, "start_platform_subscription", %{
      "platform_subscription" => %{
        "platform_price_id" => option.price.id,
        "idempotency_key" => "revoked-platform-billing-role"
      }
    })

    assert_redirect(view, "/admin?polo=#{fixture.polo_route.slug}")
  end

  test "reloads the current subscription when a stale price choice conflicts", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_polo_admin!(fixture)
    option = insert_option!()
    configure_platform_gateway!(fixture)
    session = authenticate!(admin_scope.actor_user_id)

    Req.Test.expect(MercadoPago, fn request ->
      assert {:ok, body, request} = Plug.Conn.read_body(request)
      payload = Jason.decode!(body)

      Req.Test.json(request, %{
        id: "PREAPPROVAL-#{uuid7()}",
        external_reference: payload["external_reference"],
        status: "authorized",
        auto_recurring: %{
          frequency: 1,
          frequency_type: "months",
          transaction_amount: "399.90",
          currency_id: "BRL"
        }
      })
    end)

    session_conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    {:ok, stale_view, _html} =
      live(session_conn, "/admin/platform-billing?polo=#{fixture.polo_route.slug}")

    assert {:ok, %{subscription: _subscription}} =
             PlatformBilling.start_subscription(admin_scope, %{
               "platform_price_id" => option.price.id,
               "idempotency_key" => "external-platform-subscription-start"
             })

    render_hook(stale_view, "start_platform_subscription", %{
      "platform_subscription" => %{
        "platform_price_id" => option.price.id,
        "idempotency_key" => "stale-platform-subscription-start"
      }
    })

    assert has_element?(stale_view, "#flash-error")
    assert has_element?(stale_view, "#platform-billing-subscription")
    refute has_element?(stale_view, "#platform-subscription-start-form")
  end

  test "rejects unsafe provider redirect actions before leaving the browser", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_polo_admin!(fixture)
    option = insert_option!()
    configure_platform_gateway!(fixture)
    session = authenticate!(admin_scope.actor_user_id)

    Req.Test.expect(MercadoPago, fn request ->
      assert {:ok, body, request} = Plug.Conn.read_body(request)
      payload = Jason.decode!(body)

      Req.Test.json(request, %{
        id: "PREAPPROVAL-#{uuid7()}",
        external_reference: payload["external_reference"],
        status: "authorized",
        auto_recurring: %{
          frequency: 1,
          frequency_type: "months",
          transaction_amount: "399.90",
          currency_id: "BRL"
        }
      })
    end)

    session_conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    {:ok, unsafe_url_view, _html} =
      live(session_conn, "/admin/platform-billing?polo=#{fixture.polo_route.slug}")

    {:ok, missing_url_view, _html} =
      live(session_conn, "/admin/platform-billing?polo=#{fixture.polo_route.slug}")

    idempotency_key = "provider-redirect-validation-web"

    assert {:ok, %{subscription: subscription}} =
             PlatformBilling.start_subscription(admin_scope, %{
               "platform_price_id" => option.price.id,
               "idempotency_key" => idempotency_key
             })

    set_subscription_next_action!(subscription.id, %{
      "type" => "redirect",
      "url" => "http://unsafe.example.test/checkout"
    })

    render_hook(unsafe_url_view, "start_platform_subscription", %{
      "platform_subscription" => %{
        "platform_price_id" => option.price.id,
        "idempotency_key" => idempotency_key
      }
    })

    assert has_element?(unsafe_url_view, "#platform-billing-subscription")

    set_subscription_next_action!(subscription.id, %{"type" => "redirect", "url" => nil})

    render_hook(missing_url_view, "start_platform_subscription", %{
      "platform_subscription" => %{
        "platform_price_id" => option.price.id,
        "idempotency_key" => idempotency_key
      }
    })

    assert has_element?(missing_url_view, "#platform-billing-subscription")
  end

  test "reports an unsupported provider without losing the start form", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_polo_admin!(fixture)
    option = insert_option!()
    configure_unsupported_platform_gateway!(fixture)
    session = authenticate!(admin_scope.actor_user_id)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/platform-billing?polo=#{fixture.polo_route.slug}")

    view
    |> form("#platform-subscription-start-form",
      platform_subscription: %{platform_price_id: option.price.id}
    )
    |> render_submit()

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#platform-subscription-start-form")

    assert {:ok, %{subscription: %{status: "pending"}}} =
             PlatformBilling.get_billing(admin_scope)
  end

  test "renders every persisted subscription status", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_polo_admin!(fixture)
    option = insert_option!()
    configure_platform_gateway!(fixture)
    session = authenticate!(admin_scope.actor_user_id)

    Req.Test.expect(MercadoPago, fn request ->
      assert {:ok, body, request} = Plug.Conn.read_body(request)
      payload = Jason.decode!(body)

      Req.Test.json(request, %{
        id: "PREAPPROVAL-#{uuid7()}",
        external_reference: payload["external_reference"],
        status: "authorized",
        auto_recurring: %{
          frequency: 1,
          frequency_type: "months",
          transaction_amount: "399.90",
          currency_id: "BRL"
        }
      })
    end)

    {:ok, view, _html} =
      conn
      |> put_req_header("accept-language", "en")
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/admin/platform-billing?polo=#{fixture.polo_route.slug}")

    view
    |> form("#platform-subscription-start-form",
      platform_subscription: %{platform_price_id: option.price.id}
    )
    |> render_submit()

    assert {:ok, %{subscription: subscription}} = PlatformBilling.get_billing(admin_scope)

    for {status, label} <- [
          {"past_due", "Past due"},
          {"suspended", "Suspended"},
          {"cancelled", "Cancelled"}
        ] do
      set_subscription_status!(subscription.id, status)
      render_change(view, "change_polo", %{"context" => %{"polo" => fixture.polo_route.slug}})
      assert_patch(view, "/admin/platform-billing?polo=#{fixture.polo_route.slug}")
      assert has_element?(view, "#platform-billing-subscription", label)
    end
  end

  defp insert_option! do
    plan =
      Repo.insert!(%Plan{
        code: "saas-web-#{System.unique_integer([:positive])}",
        name: "Operação web",
        status: "active"
      })

    version =
      Repo.insert!(%PlanVersion{
        platform_plan_id: plan.id,
        version: 1,
        name: "Operação web 2026",
        description: "Plano SaaS disponível para assinatura.",
        status: "published",
        published_at: DateTime.utc_now(:microsecond),
        inserted_at: DateTime.utc_now(:microsecond)
      })

    price =
      Repo.insert!(%Price{
        platform_plan_version_id: version.id,
        currency: "BRL",
        amount: Decimal.new("399.90"),
        billing_interval_unit: "month",
        billing_interval_count: 1,
        valid_during: Factory.tstz_range(DateTime.add(DateTime.utc_now(:microsecond), -60)),
        inserted_at: DateTime.utc_now(:microsecond)
      })

    %{plan: plan, version: version, price: price}
  end

  defp grant_polo_admin!(fixture) do
    ReviewsFixtures.grant_moderator!(
      %{ids: %{polo: fixture.polo.id}, scope: fixture.service_scope},
      role_key: "admin"
    )
  end

  defp configure_platform_gateway!(fixture) do
    fixture.provider
    |> Ecto.Changeset.change(code: "mercado_pago")
    |> Repo.update!()

    account =
      Factory.insert(:merchant_account,
        payment_provider: fixture.provider,
        kind: "platform",
        name: "Clubeira SaaS Live",
        provider_account_reference: "platform-live-#{uuid7()}"
      )

    previous_gateway = Application.get_env(:clubeira, MercadoPago)
    previous_billing = Application.get_env(:clubeira, :platform_billing)

    Application.put_env(:clubeira, MercadoPago,
      accounts: %{
        account.provider_account_reference => %{
          access_token: @access_token,
          webhook_secret: "platform-billing-live-webhook-secret-32-bytes"
        }
      },
      subscription_back_url: @back_url,
      req_options: [plug: {Req.Test, MercadoPago}]
    )

    Application.put_env(:clubeira, :platform_billing, merchant_account_id: account.id)

    on_exit(fn ->
      restore_env(MercadoPago, previous_gateway)
      restore_env(:platform_billing, previous_billing)
    end)
  end

  defp configure_unsupported_platform_gateway!(fixture) do
    fixture.provider
    |> Ecto.Changeset.change(code: "unsupported-platform-web")
    |> Repo.update!()

    account =
      Factory.insert(:merchant_account,
        payment_provider: fixture.provider,
        kind: "platform",
        name: "Unsupported Clubeira SaaS Live",
        provider_account_reference: "platform-unsupported-live-#{uuid7()}"
      )

    previous_billing = Application.get_env(:clubeira, :platform_billing)
    Application.put_env(:clubeira, :platform_billing, merchant_account_id: account.id)

    on_exit(fn -> restore_env(:platform_billing, previous_billing) end)
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session
  end

  defp restore_env(key, nil), do: Application.delete_env(:clubeira, key)
  defp restore_env(key, value), do: Application.put_env(:clubeira, key, value)

  defp revoke_membership!(polo_id, user_id) do
    TestDatabaseRole.as_owner(fn ->
      Repo.query!(
        "UPDATE polo_memberships SET status = 'revoked' WHERE polo_id = $1 AND user_id = $2",
        [Ecto.UUID.dump!(polo_id), Ecto.UUID.dump!(user_id)]
      )
    end)
  end

  defp set_subscription_status!(subscription_id, status) do
    TestDatabaseRole.as_owner(fn ->
      Repo.query!("UPDATE polo_platform_subscriptions SET status = $2 WHERE id = $1", [
        Ecto.UUID.dump!(subscription_id),
        status
      ])
    end)
  end

  defp set_subscription_next_action!(subscription_id, next_action) do
    TestDatabaseRole.as_owner(fn ->
      PoloSubscription
      |> Repo.get!(subscription_id)
      |> Ecto.Changeset.change(next_action: next_action)
      |> Repo.update!()
    end)
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
