defmodule ClubeiraWeb.BackofficeProductOfferingLifecycleControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Billing
  alias Clubeira.BillingFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  @password "uma-senha-forte-para-lifecycle-comercial"

  test "an admin pauses new sales without invalidating an order already placed", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    admin_token = authenticate!(admin_scope.actor_user_id)
    offering_id = fixture.offering_version.product_offering_id

    assert checkout_option?(conn, fixture, fixture.offering_version.id)

    assert {:ok, pending_order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture,
                 idempotency_key: "checkout-before-commercial-pause"
               )
             )

    assert %{
             "data" => %{
               "product_offering_id" => ^offering_id,
               "action" => "pause",
               "previous_status" => "active",
               "status" => "paused",
               "revision" => 2,
               "transitioned_at" => transitioned_at
             }
           } =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> put_req_header("idempotency-key", "product-offering-pause-001")
             |> post(lifecycle_path(fixture, offering_id), %{
               "action" => "pause",
               "reason" => "Interrupção comercial preventiva"
             })
             |> json_response(200)

    assert {:ok, _transitioned_at, 0} = DateTime.from_iso8601(transitioned_at)
    refute checkout_option?(conn, fixture, fixture.offering_version.id)

    assert {:error, :offering_unavailable} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture,
                 idempotency_key: "checkout-after-commercial-pause"
               )
             )

    assert {:ok, contract} =
             Billing.settle_payment(
               fixture.service_scope,
               BillingFixtures.settled_payment(fixture, pending_order)
             )

    assert contract.product_offering_version_id == fixture.offering_version.id
  end

  test "an admin reactivates a paused offering when its commercial graph is still sellable", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    admin_token = authenticate!(admin_scope.actor_user_id)
    offering_id = fixture.offering_version.product_offering_id

    assert %{"data" => %{"status" => "paused", "revision" => 2}} =
             transition(
               conn,
               fixture,
               offering_id,
               admin_token,
               "product-offering-before-reactivation",
               "pause",
               "Pausa para conferência da configuração"
             )

    refute checkout_option?(conn, fixture, fixture.offering_version.id)

    assert %{
             "data" => %{
               "product_offering_id" => ^offering_id,
               "action" => "reactivate",
               "previous_status" => "paused",
               "status" => "active",
               "revision" => 3
             }
           } =
             transition(
               conn,
               fixture,
               offering_id,
               admin_token,
               "product-offering-reactivation-001",
               "reactivate",
               "Configuração comercial conferida e liberada"
             )

    assert checkout_option?(conn, fixture, fixture.offering_version.id)

    assert {:ok, _order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture,
                 idempotency_key: "checkout-after-commercial-reactivation"
               )
             )
  end

  defp checkout_option?(conn, fixture, offering_version_id) do
    conn
    |> recycle()
    |> get("/api/v1/polos/#{fixture.polo_route.slug}/checkout-options")
    |> json_response(200)
    |> get_in(["data", "options"])
    |> Enum.any?(&(&1["product_offering_version_id"] == offering_version_id))
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

  defp transition(conn, fixture, offering_id, token, key, action, reason) do
    conn
    |> recycle()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("idempotency-key", key)
    |> post(lifecycle_path(fixture, offering_id), %{"action" => action, "reason" => reason})
    |> json_response(200)
  end

  defp lifecycle_path(fixture, offering_id) do
    "/api/v1/polos/#{fixture.polo_route.slug}/backoffice/product-offerings/" <>
      "#{offering_id}/lifecycle-actions"
  end
end
