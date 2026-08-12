defmodule ClubeiraWeb.Member.SubscriptionsLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Billing
  alias Clubeira.BillingFixtures
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo

  @password "uma-senha-forte-para-assinaturas-do-membro"

  test "lists only the authenticated member subscriptions", %{conn: conn} do
    fixture = BillingFixtures.create!()
    {_order, contract} = captured_subscription!(fixture)

    additional_contracts =
      for status <- ~w(pending past_due suspended cancelled expired) do
        RedemptionsFixtures.create!(
          user_id: fixture.user.id,
          insert_user: false,
          contract_status: status
        )
      end

    other = BillingFixtures.create!()
    {_other_order, other_contract} = captured_subscription!(other)
    session = authenticate!(fixture.user)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/subscriptions")

    assert has_element?(view, "#member-subscriptions")
    assert has_element?(view, "#member-subscription-#{contract.id}")

    for additional <- additional_contracts do
      assert has_element?(view, "#member-subscription-#{additional.ids.access_contract}")
    end

    refute has_element?(view, "#member-subscription-#{other_contract.id}")
    assert has_element?(view, "#member-nav-subscriptions[aria-current='page']")
    assert has_element?(view, "#member-subscriptions-list", "Ativo")
    assert has_element?(view, "#member-subscriptions-list", "Pendente")
    assert has_element?(view, "#member-subscriptions-list", "Inadimplente")
    assert has_element?(view, "#member-subscriptions-list", "Suspenso")
    assert has_element?(view, "#member-subscriptions-list", "Cancelado")
    assert has_element?(view, "#member-subscriptions-list", "Expirado")
  end

  test "uses the account route keyset without retaining the previous page", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()

    second_fixture =
      RedemptionsFixtures.create!(user_id: fixture.ids.user, insert_user: false)

    first_contract = %{id: fixture.ids.access_contract}
    second_contract = %{id: second_fixture.ids.access_contract}
    session = fixture.ids.user |> then(&Repo.get!(User, &1)) |> authenticate!()

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/subscriptions?limit=1")

    visible =
      [first_contract, second_contract]
      |> Enum.filter(&has_element?(view, "#member-subscription-#{&1.id}"))

    assert length(visible) == 1

    view |> element("#member-subscriptions-next-page") |> render_click()
    assert_patch(view)

    [previous] = visible
    refute has_element?(view, "#member-subscription-#{previous.id}")
  end

  test "canonicalizes an invalid account-route cursor", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    session = fixture.ids.user |> then(&Repo.get!(User, &1)) |> authenticate!()

    assert {:error, {:redirect, %{to: "/app/subscriptions"}}} =
             conn
             |> init_test_session(%{"backoffice_session_token" => session.token})
             |> live("/app/subscriptions?after=malformed")
  end

  defp captured_subscription!(fixture) do
    assert {:ok, order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture,
                 idempotency_key: "checkout-#{Ecto.UUID.generate()}"
               )
             )

    assert {:ok, contract} =
             Billing.settle_payment(
               fixture.service_scope,
               BillingFixtures.settled_payment(fixture, order,
                 external_event_id: "evt-#{Ecto.UUID.generate()}",
                 provider_reference: "pay-#{Ecto.UUID.generate()}"
               )
             )

    {order, contract}
  end

  defp authenticate!(user) do
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session
  end
end
