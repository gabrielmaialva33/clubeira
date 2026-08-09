defmodule ClubeiraWeb.BackofficeSubscriptionLifecycleControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Billing
  alias Clubeira.BillingFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  @password "uma-senha-forte-para-lifecycle-de-assinaturas"

  test "a billing admin suspends and reactivates a subscription through the routed API", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    admin_token = authenticate!(admin_scope.actor_user_id)
    member_token = authenticate!(fixture.user.id)
    contract = captured_contract!(fixture)

    path =
      "/api/v1/polos/#{fixture.polo_route.slug}/backoffice/subscriptions/#{contract.id}/lifecycle-actions"

    assert conn
           |> put_req_header("authorization", "Bearer #{member_token}")
           |> put_req_header("idempotency-key", "member-contract-suspension")
           |> post(path, %{"action" => "suspend", "reason" => "Sem autorização administrativa"})
           |> json_response(403) == %{"errors" => %{"detail" => "Forbidden"}}

    first =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{admin_token}")
      |> put_req_header("idempotency-key", "admin-contract-suspension")
      |> post(path, %{
        "action" => "suspend",
        "reason" => "Pendência financeira confirmada"
      })
      |> json_response(200)

    assert %{
             "data" => %{
               "access_contract_id" => contract_id,
               "previous_status" => "active",
               "status" => "suspended",
               "event_sequence" => 2
             }
           } = first

    assert contract_id == contract.id

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "admin-contract-suspension")
           |> post(path, %{
             "action" => "suspend",
             "reason" => "Pendência financeira confirmada"
           })
           |> json_response(200) == first

    assert %{"data" => [%{"id" => ^contract_id, "status" => "suspended"}]} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(
               "/api/v1/polos/#{fixture.polo_route.slug}/backoffice/subscriptions?status=suspended"
             )
             |> json_response(200)

    assert %{
             "data" => %{
               "access_contract_id" => ^contract_id,
               "previous_status" => "suspended",
               "status" => "active",
               "event_sequence" => 3
             }
           } =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> put_req_header("idempotency-key", "admin-contract-reactivation")
             |> post(path, %{
               "action" => "reactivate",
               "reason" => "Pendência financeira regularizada"
             })
             |> json_response(200)
  end

  defp captured_contract!(fixture) do
    assert {:ok, order} =
             Billing.place_order(fixture.member_scope, BillingFixtures.checkout_request(fixture))

    assert {:ok, contract} =
             Billing.settle_payment(
               fixture.service_scope,
               BillingFixtures.settled_payment(fixture, order)
             )

    contract
  end

  defp grant_admin!(fixture) do
    ReviewsFixtures.grant_moderator!(
      %{ids: %{polo: fixture.polo.id}, scope: fixture.service_scope},
      role_key: "admin"
    )
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session.token
  end
end
