defmodule ClubeiraWeb.Backoffice.ProductOfferingLifecycleControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  import Ecto.Query

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Audit.TenantEvent
  alias Clubeira.Billing
  alias Clubeira.BillingFixtures
  alias Clubeira.Events.DomainEvent
  alias Clubeira.Events.OutboxMessage
  alias Clubeira.Idempotency.Key
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

  test "retirement is terminal, stops new sales and preserves historical settlement", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    admin_token = authenticate!(admin_scope.actor_user_id)
    offering_id = fixture.offering_version.product_offering_id

    assert {:ok, pending_order} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture,
                 idempotency_key: "checkout-before-commercial-retirement"
               )
             )

    assert %{
             "data" => %{
               "product_offering_id" => ^offering_id,
               "action" => "retire",
               "previous_status" => "active",
               "status" => "retired",
               "revision" => 2
             }
           } =
             transition(
               conn,
               fixture,
               offering_id,
               admin_token,
               "product-offering-retirement-001",
               "retire",
               "Oferta encerrada definitivamente"
             )

    refute checkout_option?(conn, fixture, fixture.offering_version.id)

    assert {:error, :offering_unavailable} =
             Billing.place_order(
               fixture.member_scope,
               BillingFixtures.checkout_request(fixture,
                 idempotency_key: "checkout-after-commercial-retirement"
               )
             )

    assert {:ok, contract} =
             Billing.settle_payment(
               fixture.service_scope,
               BillingFixtures.settled_payment(fixture, pending_order)
             )

    assert contract.product_offering_version_id == fixture.offering_version.id

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "product-offering-retired-reactivation")
           |> post(lifecycle_path(fixture, offering_id), %{
             "action" => "reactivate",
             "reason" => "Tentativa de reabrir identidade encerrada"
           })
           |> json_response(409) == %{
             "errors" => %{
               "code" => "invalid_product_offering_transition",
               "detail" => "Conflict"
             }
           }
  end

  test "an exact retry preserves one observable transition and keeps its reason private", %{
    conn: conn
  } do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    admin_token = authenticate!(admin_scope.actor_user_id)
    offering_id = fixture.offering_version.product_offering_id
    key = "product-offering-observable-pause"
    reason = "Revisão confidencial da estratégia comercial"

    first =
      transition(conn, fixture, offering_id, admin_token, key, "pause", reason)

    replayed =
      transition(conn, fixture, offering_id, admin_token, key, "pause", reason)

    assert replayed == first

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", key)
           |> post(lifecycle_path(fixture, offering_id), %{
             "action" => "pause",
             "reason" => "Conteúdo diferente para a mesma chave"
           })
           |> json_response(409) == %{
             "errors" => %{"code" => "idempotency_conflict", "detail" => "Conflict"}
           }

    assert {:ok, :verified} =
             Repo.transact_in_polo(admin_scope, fn repo ->
               event =
                 repo.one!(
                   from(event in DomainEvent,
                     where:
                       event.aggregate_type == "product_offering" and
                         event.aggregate_id == ^offering_id and
                         event.event_type == "product_offering.paused"
                   )
                 )

               audit =
                 repo.one!(
                   from(audit in TenantEvent,
                     where:
                       audit.resource_id == ^offering_id and
                         audit.action == "product_offering.paused"
                   )
                 )

               outbox = repo.get_by!(OutboxMessage, domain_event_id: event.id)

               idempotency =
                 repo.one!(
                   from(idempotency in Key,
                     where:
                       idempotency.scope == "subscriptions.transition_product_offering" and
                         idempotency.idempotency_key == ^key
                   )
                 )

               assert event.aggregate_version == 2
               assert outbox.topic == "subscriptions.product_offerings.paused"
               assert outbox.message_key == offering_id
               assert audit.metadata["reason"] == reason
               assert idempotency.resource_id == offering_id
               assert idempotency.response_body == first["data"]

               public_evidence =
                 inspect([
                   first,
                   event.payload,
                   event.metadata,
                   outbox.payload,
                   idempotency.response_body
                 ])

               refute public_evidence =~ reason

               {:ok, :verified}
             end)
  end

  test "only an admin of the routed polo can transition an offering", %{conn: conn} do
    fixture = BillingFixtures.create!()
    other_polo = BillingFixtures.create!()

    moderator_scope =
      ReviewsFixtures.grant_moderator!(%{
        ids: %{polo: fixture.polo.id},
        scope: fixture.service_scope
      })

    admin_scope = grant_admin!(fixture)
    moderator_token = authenticate!(moderator_scope.actor_user_id)
    admin_token = authenticate!(admin_scope.actor_user_id)
    offering_id = fixture.offering_version.product_offering_id
    other_offering_id = other_polo.offering_version.product_offering_id

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{moderator_token}")
           |> put_req_header("idempotency-key", "product-offering-moderator-forbidden")
           |> post(lifecycle_path(fixture, offering_id), %{
             "action" => "pause",
             "reason" => "Tentativa sem capacidade administrativa"
           })
           |> json_response(403) == %{"errors" => %{"detail" => "Forbidden"}}

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "product-offering-cross-polo-hidden")
           |> post(lifecycle_path(fixture, other_offering_id), %{
             "action" => "pause",
             "reason" => "Tentativa sobre identidade de outro polo"
           })
           |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}

    assert checkout_option?(conn, fixture, fixture.offering_version.id)
    assert checkout_option?(conn, other_polo, other_polo.offering_version.id)
  end

  test "invalid lifecycle contracts fail before reserving an idempotency key", %{conn: conn} do
    fixture = BillingFixtures.create!()
    admin_scope = grant_admin!(fixture)
    admin_token = authenticate!(admin_scope.actor_user_id)
    offering_id = fixture.offering_version.product_offering_id

    invalid_requests = [
      {"product-offering-invalid-action",
       %{
         "action" => "archive",
         "reason" => "Ação não suportada"
       }},
      {"product-offering-invalid-reason", %{"action" => "pause", "reason" => "  "}},
      {"short", %{"action" => "pause", "reason" => "Chave curta"}}
    ]

    Enum.each(invalid_requests, fn {key, body} ->
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> put_req_header("idempotency-key", key)
             |> post(lifecycle_path(fixture, offering_id), body)
             |> json_response(422) == %{
               "errors" => %{"detail" => "Unprocessable Content"}
             }
    end)

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> post(lifecycle_path(fixture, offering_id), %{
             "action" => "pause",
             "reason" => "Header ausente"
           })
           |> json_response(400) == %{
             "errors" => %{
               "code" => "invalid_idempotency_key",
               "detail" => "Bad Request"
             }
           }

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "product-offering-invalid-id")
           |> post(lifecycle_path(fixture, "not-a-uuid"), %{
             "action" => "pause",
             "reason" => "Identidade inválida"
           })
           |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}

    assert {:ok, 0} =
             Repo.transact_in_polo(admin_scope, fn repo ->
               count =
                 repo.aggregate(
                   from(key in Key,
                     where:
                       key.scope == "subscriptions.transition_product_offering" and
                         like(key.idempotency_key, "product-offering-invalid%")
                   ),
                   :count
                 )

               {:ok, count}
             end)
  end

  test "an invalid state transition is audited once and replays stably", %{conn: conn} do
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
               "product-offering-valid-pause",
               "pause",
               "Primeira pausa comercial"
             )

    key = "product-offering-duplicate-pause"
    offering_uuid = Ecto.UUID.dump!(offering_id)

    for _retry <- 1..2 do
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> put_req_header("idempotency-key", key)
             |> post(lifecycle_path(fixture, offering_id), %{
               "action" => "pause",
               "reason" => "Pausa repetida sobre estado já pausado"
             })
             |> json_response(409) == %{
               "errors" => %{
                 "code" => "invalid_product_offering_transition",
                 "detail" => "Conflict"
               }
             }
    end

    assert {:ok, %{rows: [["paused", 2, 1, 1]]}} =
             Repo.transact_in_polo(admin_scope, fn repo ->
               {:ok,
                repo.query!(
                  """
                  SELECT
                    offering.status,
                    offering.revision,
                    (
                      SELECT count(*)
                      FROM tenant_idempotency_keys
                      WHERE scope = 'subscriptions.transition_product_offering'
                        AND idempotency_key = $2
                        AND status = 'failed'
                    ),
                    (
                      SELECT count(*)
                      FROM tenant_audit_events
                      WHERE resource_id = $1
                        AND action = 'product_offering.transition_rejected'
                    )
                  FROM product_offerings AS offering
                  WHERE offering.id = $1
                  """,
                  [offering_uuid, key]
                )}
             end)
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
