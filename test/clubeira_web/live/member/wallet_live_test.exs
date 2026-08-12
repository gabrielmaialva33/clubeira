defmodule ClubeiraWeb.Member.WalletLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Devices.DeviceInstallation
  alias Clubeira.Redemptions
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo

  @password "uma-senha-forte-para-a-carteira-do-membro"

  test "shows only the selected polo wallet and redemption history", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()

    other =
      RedemptionsFixtures.create!(user_id: fixture.ids.user, insert_user: false)

    assert {:ok, redemption} = Redemptions.confirm(fixture.scope, fixture.request)
    session = authenticate!(fixture.ids.user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/wallet?polo=#{fixture.polo_slug}")

    assert has_element?(view, "#member-wallet")
    assert has_element?(view, "#member-nav-wallet[aria-current='page']")
    assert has_element?(view, "#voucher-#{fixture.ids.entitlement_allocation}")
    refute has_element?(view, "#voucher-#{other.ids.entitlement_allocation}")
    assert has_element?(view, "#member-redemption-#{redemption.id}")

    view
    |> form("#wallet-polo-switcher", wallet: %{polo: other.polo_slug})
    |> render_change()

    assert_patch(view, "/app/wallet?polo=#{other.polo_slug}")
    assert has_element?(view, "#voucher-#{other.ids.entitlement_allocation}")
    refute has_element?(view, "#voucher-#{fixture.ids.entitlement_allocation}")
  end

  test "renders the percentage value of a percentage discount voucher", %{conn: conn} do
    fixture =
      RedemptionsFixtures.create!(
        benefit_kind: "discount_percentage",
        percentage_value: Decimal.new("12.5")
      )

    session = authenticate!(fixture.ids.user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/wallet?polo=#{fixture.polo_slug}")

    assert has_element?(
             view,
             "#voucher-#{fixture.ids.entitlement_allocation} [data-benefit-value]",
             "12,50%"
           )
  end

  test "renders an amount voucher and activity timestamp in the requested locale", %{conn: conn} do
    fixture =
      RedemptionsFixtures.create!(
        benefit_kind: "discount_amount",
        amount_value: Decimal.new("15.75"),
        currency: "BRL"
      )

    assert {:ok, redemption} = Redemptions.confirm(fixture.scope, fixture.request)
    session = authenticate!(fixture.ids.user)

    {:ok, view, _html} =
      conn
      |> put_req_header("accept-language", "en")
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/wallet?polo=#{fixture.polo_slug}")

    assert has_element?(
             view,
             "#voucher-#{fixture.ids.entitlement_allocation} [data-benefit-value]",
             "BRL 15.75"
           )

    assert has_element?(
             view,
             "#member-redemption-#{redemption.id}",
             "#{redemption.redeemed_at.year}-"
           )
  end

  test "submits a verified review with redemption and place bound by the server", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    assert {:ok, redemption} = Redemptions.confirm(fixture.scope, fixture.request)
    session = authenticate!(fixture.ids.user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/wallet?polo=#{fixture.polo_slug}")

    view
    |> element("#review-redemption-#{redemption.id}")
    |> render_click()

    assert has_element?(view, "#member-review-form")
    refute has_element?(view, "#member-review-form [name$='[place_id]']")
    refute has_element?(view, "#member-review-form [name$='[source_redemption_id]']")
    refute has_element?(view, "#member-review-form [name$='[idempotency_key]']")

    view
    |> form("#member-review-form",
      submission: %{
        rating: "5",
        title: "Experiência excelente",
        body: "O benefício foi entregue exatamente como anunciado."
      }
    )
    |> render_submit()

    assert has_element?(
             view,
             "#member-redemption-#{redemption.id} [data-review-status='pending']"
           )

    refute has_element?(view, "#member-review-form")
  end

  test "revalidates the session before submitting a review", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    assert {:ok, redemption} = Redemptions.confirm(fixture.scope, fixture.request)
    session = authenticate!(fixture.ids.user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/wallet?polo=#{fixture.polo_slug}")

    view |> element("#review-redemption-#{redemption.id}") |> render_click()

    assert {:ok, account_scope} = Accounts.fetch_scope_by_api_token(session.token)
    assert :ok = Accounts.revoke_session(account_scope)

    assert {:error, {:redirect, %{to: "/app/login"}}} =
             view
             |> form("#member-review-form",
               submission: %{rating: "5", body: "Não deve persistir."}
             )
             |> render_submit()
  end

  test "validates, cancels, and rejects malformed or unavailable review requests", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    assert {:ok, redemption} = Redemptions.confirm(fixture.scope, fixture.request)
    session = authenticate!(fixture.ids.user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/wallet?polo=#{fixture.polo_slug}")

    view |> element("#review-redemption-#{redemption.id}") |> render_click()

    render_change(view, "validate_review", %{
      "submission" => %{"rating" => "9", "body" => ""}
    })

    assert has_element?(view, "#submission_rating.border-red-500")
    assert has_element?(view, "#submission_body.border-red-500")

    view
    |> form("#member-review-form", submission: %{rating: "1", body: ""})
    |> render_submit()

    assert has_element?(view, "#submission_body.border-red-500")

    view |> element("#cancel-member-review") |> render_click()
    refute has_element?(view, "#member-review-form")

    render_hook(view, "review_redemption", %{"redemption-id" => Ecto.UUID.generate()})
    assert has_element?(view, "#flash-error")

    render_hook(view, "review_redemption", %{})
    render_hook(view, "validate_review", %{})
    render_hook(view, "submit_review", %{"submission" => %{"rating" => "5"}})
    render_hook(view, "submit_review", %{})
    render_hook(view, "change_wallet_polo", %{})
    render_hook(view, "prepare_redemption", %{})
    render_hook(view, "prepare_redemption", %{"allocation-id" => Ecto.UUID.generate()})
    render_hook(view, "issue_redemption_grant", %{})

    render_hook(view, "issue_redemption_grant", %{
      "installation_token" => Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    })

    render_hook(view, "prepare_redemption", %{
      "allocation-id" => fixture.ids.entitlement_allocation
    })

    render_hook(view, "issue_redemption_grant", %{"installation_token" => "too-short"})

    assert has_element?(view, "#member-wallet")
    refute has_element?(view, "#member-review-form")
    refute has_element?(view, "#member-redemption-grant")
  end

  test "canonicalizes an invalid redemption cursor", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    session = authenticate!(fixture.ids.user)

    assert {:error, {:redirect, %{to: "/app/wallet"}}} =
             conn
             |> init_test_session(%{"backoffice_session_token" => session.token})
             |> live("/app/wallet?polo=#{fixture.polo_slug}&after=malformed")
  end

  test "sends a member without subscriptions back to the catalog", %{conn: conn} do
    user = Clubeira.Factory.insert(:user)
    session = authenticate!(user.id)

    assert {:error, {:redirect, %{to: "/app/catalog"}}} =
             conn
             |> init_test_session(%{"backoffice_session_token" => session.token})
             |> live("/app/wallet")
  end

  test "enrolls the current browser and issues a short-lived grant for a server-bound voucher", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!(authorize_device: false)
    other = RedemptionsFixtures.create!()
    session = authenticate!(fixture.ids.user)
    installation_token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/wallet?polo=#{fixture.polo_slug}")

    view
    |> element("#redeem-voucher-#{fixture.ids.entitlement_allocation}")
    |> render_click()

    view
    |> element("#member-device-installation")
    |> render_hook("issue_redemption_grant", %{
      "installation_token" => installation_token,
      "allocation_id" => other.ids.entitlement_allocation
    })

    assert has_element?(view, "#member-redemption-grant")
    assert has_element?(view, "#member-redemption-grant-token")
    refute render(view) =~ installation_token

    assert Repo.aggregate(DeviceInstallation, :count) >= 1

    assert %{rows: [[1]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT count(*)
               FROM contract_redemption_devices
               WHERE access_contract_id = $1 AND status = 'active'
               """,
               [fixture.ids.access_contract]
             )

    refute Repo.exists?(
             from authorization in Clubeira.Devices.ContractRedemptionDevice,
               where: authorization.access_contract_id == ^other.ids.access_contract
           )
  end

  test "revalidates the session before issuing a browser redemption grant", %{conn: conn} do
    fixture = RedemptionsFixtures.create!(authorize_device: false)
    session = authenticate!(fixture.ids.user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/wallet?polo=#{fixture.polo_slug}")

    view
    |> element("#redeem-voucher-#{fixture.ids.entitlement_allocation}")
    |> render_click()

    assert {:ok, account_scope} = Accounts.fetch_scope_by_api_token(session.token)
    assert :ok = Accounts.revoke_session(account_scope)

    assert {:error, {:redirect, %{to: "/app/login"}}} =
             view
             |> element("#member-device-installation")
             |> render_hook("issue_redemption_grant", %{
               "installation_token" =>
                 Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
             })

    refute Repo.exists?(
             from authorization in Clubeira.Devices.ContractRedemptionDevice,
               where: authorization.access_contract_id == ^fixture.ids.access_contract
           )
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session
  end
end
