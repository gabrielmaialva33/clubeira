defmodule ClubeiraWeb.Member.CatalogLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.Billing
  alias Clubeira.Billing.Gateways.MercadoPago
  alias Clubeira.BillingFixtures
  alias Clubeira.Directory.Place
  alias Clubeira.Factory
  alias Clubeira.Repo
  alias Clubeira.Subscriptions.ProductOffering

  @password "uma-senha-forte-para-o-catalogo-do-membro"
  @access_token "catalog-live-access-token"
  @webhook_secret "catalog-live-webhook-secret-with-32-bytes"

  test "shows one selected polo catalog without leaking another polo", %{conn: conn} do
    fixture = BillingFixtures.create!()
    other = BillingFixtures.create!()
    session = authenticate!(fixture.user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/catalog?polo=#{fixture.polo_route.slug}")

    assert has_element?(view, "#member-catalog")

    assert has_element?(
             view,
             "#catalog-polo option[value='#{fixture.polo_route.slug}'][selected]"
           )

    assert has_element?(view, "#checkout-option-#{fixture.price.id}")
    refute has_element?(view, "#checkout-option-#{other.price.id}")
    assert has_element?(view, "#member-nav-catalog[aria-current='page']")

    place = Repo.get!(Place, fixture.polo_place.place_id)

    assert has_element?(
             view,
             "[id^='catalog-place-reviews-'][href='/app/catalog/#{fixture.polo_route.slug}/places/#{place.slug}/reviews']"
           )

    view
    |> form("#catalog-polo-switcher", catalog: %{polo: other.polo_route.slug})
    |> render_change()

    assert_patch(view, "/app/catalog?polo=#{other.polo_route.slug}")
    assert has_element?(view, "#checkout-option-#{other.price.id}")
    refute has_element?(view, "#checkout-option-#{fixture.price.id}")
  end

  test "paginates benefits and renders percentage and amount discounts", %{conn: conn} do
    fixture = BillingFixtures.create!()

    assert {:ok, {percentage_version, amount_version}} =
             Repo.transact_in_polo(fixture.member_scope, fn ->
               percentage_version =
                 insert_benefit!(fixture,
                   benefit_kind: "discount_percentage",
                   percentage_value: Decimal.new("12.5")
                 )

               amount_version =
                 insert_benefit!(fixture,
                   benefit_kind: "discount_amount",
                   amount_value: Decimal.new("7.50"),
                   currency: "BRL"
                 )

               {:ok, {percentage_version, amount_version}}
             end)

    session = authenticate!(fixture.user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/catalog?polo=#{fixture.polo_route.slug}")

    assert has_element?(
             view,
             "#catalog-offer-#{percentage_version.id}",
             "12.5000%"
           )

    assert has_element?(
             view,
             "#catalog-offer-#{amount_version.id}",
             "BRL 7.50"
           )

    render_patch(view, "/app/catalog?polo=#{fixture.polo_route.slug}&limit=1")
    assert has_element?(view, "#catalog-next-page")

    view
    |> element("#catalog-next-page")
    |> render_click()

    assert_patch(view)
  end

  test "places an idempotent order and starts its Pix payment", %{conn: conn} do
    fixture = BillingFixtures.create!()
    configure_mercado_pago!(fixture)
    session = authenticate!(fixture.user)
    copy_paste_code = "000201010212clubeira-catalog-live-pix"

    Req.Test.expect(MercadoPago, fn request ->
      request
      |> Plug.Conn.put_status(:created)
      |> Req.Test.json(%{
        id: "ORD-CATALOG-LIVE",
        status: "action_required",
        transactions: %{
          payments: [
            %{
              id: "PAY-CATALOG-LIVE",
              status: "action_required",
              status_detail: "waiting_transfer",
              amount: "29.90",
              payment_method: %{
                id: "pix",
                type: "bank_transfer",
                ticket_url: "https://www.mercadopago.com.br/sandbox/ticket/catalog-live",
                qr_code: copy_paste_code,
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
      |> live("/app/catalog?polo=#{fixture.polo_route.slug}")

    view
    |> element("#checkout-option-#{fixture.price.id} button")
    |> render_click()

    assert has_element?(view, "#checkout-result")
    assert has_element?(view, "#checkout-pix-copy-paste", copy_paste_code)

    assert {:ok, %{orders: [order]}} = Billing.list_orders(fixture.member_scope, %{})
    assert order.status == "awaiting_payment"
  end

  test "does not offer automatic renewal before member cancellation is operational", %{conn: conn} do
    fixture = BillingFixtures.create!()

    assert {:ok, _offering_version} =
             Repo.transact_in_polo(fixture.member_scope, fn ->
               fixture.offering_version
               |> Ecto.Changeset.change(renewal_policy: "automatic")
               |> Repo.update()
             end)

    session = authenticate!(fixture.user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/catalog?polo=#{fixture.polo_route.slug}")

    refute has_element?(view, "#checkout-option-#{fixture.price.id}")

    view
    |> render_click("checkout", %{"price-id" => fixture.price.id})

    assert has_element?(view, "#flash-error")
    assert {:ok, %{orders: []}} = Billing.list_orders(fixture.member_scope, %{})
  end

  test "canonicalizes pagination and rejects malformed browser events", %{conn: conn} do
    fixture = BillingFixtures.create!()
    session = authenticate!(fixture.user)
    authenticated_conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: "/app/catalog"}}} =
             live(
               authenticated_conn,
               "/app/catalog?polo=#{fixture.polo_route.slug}&after=malformed"
             )

    {:ok, view, _html} =
      live(authenticated_conn, "/app/catalog?polo=#{fixture.polo_route.slug}")

    render_hook(view, "change_catalog_polo", %{})
    render_hook(view, "checkout", %{})
    render_hook(view, "checkout", %{"price-id" => Ecto.UUID.generate(version: 7)})

    assert has_element?(view, "#member-catalog")
    assert has_element?(view, "#flash-error")
    assert {:ok, %{orders: []}} = Billing.list_orders(fixture.member_scope, %{})
  end

  test "revalidates the session immediately before checkout", %{conn: conn} do
    fixture = BillingFixtures.create!()
    session = authenticate!(fixture.user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/catalog?polo=#{fixture.polo_route.slug}")

    assert {:ok, account_scope} = Accounts.fetch_scope_by_api_token(session.token)
    assert :ok = Accounts.revoke_session(account_scope)

    assert {:error, {:redirect, %{to: "/app/login"}}} =
             view
             |> element("#checkout-option-#{fixture.price.id} button")
             |> render_click()

    assert {:ok, %{orders: []}} = Billing.list_orders(fixture.member_scope, %{})
  end

  test "rejects an offer that became unavailable after the catalog loaded", %{conn: conn} do
    fixture = BillingFixtures.create!()
    session = authenticate!(fixture.user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/catalog?polo=#{fixture.polo_route.slug}")

    assert {:ok, _offering} =
             Repo.transact_in_polo(fixture.member_scope, fn ->
               fixture.offering_version.product_offering_id
               |> then(&Repo.get!(ProductOffering, &1))
               |> Ecto.Changeset.change(status: "paused")
               |> Repo.update()
             end)

    view
    |> element("#checkout-option-#{fixture.price.id} button")
    |> render_click()

    assert has_element?(view, "#flash-error")
    assert {:ok, %{orders: []}} = Billing.list_orders(fixture.member_scope, %{})
  end

  test "keeps the order resumable when the PSP cannot start Pix", %{conn: conn} do
    fixture = BillingFixtures.create!()
    configure_mercado_pago!(fixture)
    session = authenticate!(fixture.user)

    Req.Test.expect(MercadoPago, fn request ->
      request
      |> Plug.Conn.put_status(:service_unavailable)
      |> Req.Test.json(%{message: "temporarily unavailable"})
    end)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/catalog?polo=#{fixture.polo_route.slug}")

    view
    |> element("#checkout-option-#{fixture.price.id} button")
    |> render_click()

    assert has_element?(view, "#checkout-result")
    refute has_element?(view, "#checkout-pix-copy-paste")
    assert has_element?(view, "#checkout-result a[href^='/app/orders']")
    assert has_element?(view, "#flash-error")

    assert {:ok, %{orders: [order]}} = Billing.list_orders(fixture.member_scope, %{})
    assert order.status == "awaiting_payment"
  end

  test "keeps the order resumable when the PSP response contains an unsafe URL", %{conn: conn} do
    fixture = BillingFixtures.create!()
    configure_mercado_pago!(fixture)
    session = authenticate!(fixture.user)

    Req.Test.expect(MercadoPago, fn request ->
      request
      |> Plug.Conn.put_status(:created)
      |> Req.Test.json(%{
        id: "ORD-CATALOG-LIVE-WITHOUT-ACTION",
        status: "action_required",
        transactions: %{
          payments: [
            %{
              id: "PAY-CATALOG-LIVE-WITHOUT-ACTION",
              status: "action_required",
              status_detail: "waiting_transfer",
              amount: "29.90",
              payment_method: %{
                id: "pix",
                type: "bank_transfer",
                ticket_url: "javascript:alert(1)",
                qr_code: "000201010212clubeira-catalog-live-safe-link",
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
      |> live("/app/catalog?polo=#{fixture.polo_route.slug}")

    view
    |> element("#checkout-option-#{fixture.price.id} button")
    |> render_click()

    assert has_element?(view, "#checkout-result")
    assert has_element?(view, "#checkout-result a[href^='/app/orders']")
    refute has_element?(view, "#checkout-pix-copy-paste")
    refute has_element?(view, "#checkout-pix-provider-link")
    assert has_element?(view, "#flash-error")

    assert {:ok, %{orders: [order]}} = Billing.list_orders(fixture.member_scope, %{})
    assert order.status == "awaiting_payment"
  end

  defp configure_mercado_pago!(fixture) do
    fixture.provider
    |> Ecto.Changeset.change(code: "mercado_pago")
    |> Clubeira.Repo.update!()

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
      if previous,
        do: Application.put_env(:clubeira, MercadoPago, previous),
        else: Application.delete_env(:clubeira, MercadoPago)
    end)
  end

  defp insert_benefit!(fixture, attributes) do
    offer =
      Factory.insert(:benefit_offer,
        polo: fixture.polo,
        benefit_kind: Keyword.fetch!(attributes, :benefit_kind)
      )

    version =
      Factory.insert(:benefit_offer_version,
        polo: fixture.polo,
        benefit_offer: offer,
        percentage_value: Keyword.get(attributes, :percentage_value),
        amount_value: Keyword.get(attributes, :amount_value),
        currency: Keyword.get(attributes, :currency)
      )

    Factory.insert(:benefit_offer_version_place,
      polo: fixture.polo,
      benefit_offer_version: version,
      polo_place: fixture.polo_place
    )

    version
  end

  defp authenticate!(user) do
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session
  end
end
