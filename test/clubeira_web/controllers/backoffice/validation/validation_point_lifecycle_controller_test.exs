defmodule ClubeiraWeb.Backoffice.ValidationPointLifecycleControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  import Ecto.Query

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Audit.TenantEvent
  alias Clubeira.Events.DomainEvent
  alias Clubeira.Events.OutboxMessage
  alias Clubeira.Idempotency.Key
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  @password "uma-senha-de-administracao-forte"

  test "a polo admin suspends a validation point and blocks its authentication", %{conn: conn} do
    {validation_secret, validation_digest} = validation_material()
    fixture = RedemptionsFixtures.create!(validation_credential_secret: validation_secret)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    grant = issue_grant!(conn, fixture)

    response =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{admin_token}")
      |> put_req_header("idempotency-key", "validation-point-suspension-001")
      |> post(lifecycle_path(fixture), %{
        "action" => "suspend",
        "reason" => "Manutenção emergencial do terminal"
      })
      |> json_response(200)

    assert %{
             "data" => %{
               "validation_point_id" => validation_point_id,
               "action" => "suspend",
               "previous_status" => "active",
               "status" => "suspended",
               "revision" => 2,
               "transitioned_at" => transitioned_at
             }
           } = response

    assert validation_point_id == fixture.ids.validation_point
    assert {:ok, _transitioned_at, 0} = DateTime.from_iso8601(transitioned_at)
    refute inspect(response) =~ validation_secret
    refute inspect(response) =~ validation_digest

    denied =
      conn
      |> recycle()
      |> put_req_header("authorization", "Validation #{validation_secret}")
      |> put_req_header("idempotency-key", "suspended-point-redemption")
      |> post("/api/v1/polos/#{fixture.polo_slug}/redemptions", %{"grant" => grant})

    assert json_response(denied, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    assert get_resp_header(denied, "www-authenticate") != []
  end

  test "reactivation restores authentication with the preserved credential", %{conn: conn} do
    {validation_secret, _validation_digest} = validation_material()
    fixture = RedemptionsFixtures.create!(validation_credential_secret: validation_secret)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    grant = issue_grant!(conn, fixture)

    assert %{"data" => %{"status" => "suspended", "revision" => 2}} =
             transition(
               conn,
               fixture,
               admin_token,
               "validation-point-before-reactivation",
               "suspend",
               "Troca de equipamento em andamento"
             )

    assert %{
             "data" => %{
               "validation_point_id" => validation_point_id,
               "action" => "reactivate",
               "previous_status" => "suspended",
               "status" => "active",
               "revision" => 3
             }
           } =
             transition(
               conn,
               fixture,
               admin_token,
               "validation-point-reactivation-001",
               "reactivate",
               "Novo equipamento instalado e validado"
             )

    assert validation_point_id == fixture.ids.validation_point

    assert %{"data" => %{"validation_point_id" => ^validation_point_id}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Validation #{validation_secret}")
             |> put_req_header("idempotency-key", "reactivated-point-redemption")
             |> post("/api/v1/polos/#{fixture.polo_slug}/redemptions", %{"grant" => grant})
             |> json_response(201)
  end

  test "rotation prepares a suspended point without enabling it before reactivation", %{
    conn: conn
  } do
    {current_secret, _current_digest} = validation_material()
    fixture = RedemptionsFixtures.create!(validation_credential_secret: current_secret)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    grant = issue_grant!(conn, fixture)
    {replacement_secret, replacement_digest} = validation_material()

    assert %{"data" => %{"status" => "suspended", "revision" => 2}} =
             transition(
               conn,
               fixture,
               admin_token,
               "validation-point-suspend-before-key-replacement",
               "suspend",
               "Troca preventiva do equipamento e da chave"
             )

    RedemptionsFixtures.scoped_query!(
      fixture,
      """
      UPDATE validation_credentials
         SET valid_during = tstzrange(
           statement_timestamp() - interval '2 days',
           statement_timestamp() - interval '1 day',
           '[)'
         )
       WHERE id = $1
      """,
      [fixture.ids.validation_credential]
    )

    rotation_path =
      "/api/v1/polos/#{fixture.polo_slug}/backoffice/validation-credentials/" <>
        "#{fixture.ids.validation_credential}/rotations"

    assert %{"data" => %{"credential" => %{"version" => 2, "status" => "active"}}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> put_req_header("idempotency-key", "suspended-point-key-replacement")
             |> post(rotation_path, %{
               "credential" => %{
                 "secret_sha256" => replacement_digest,
                 "expires_at" => fixture.now |> DateTime.add(90, :day) |> DateTime.to_iso8601()
               }
             })
             |> json_response(201)

    denied =
      conn
      |> recycle()
      |> put_req_header("authorization", "Validation #{replacement_secret}")
      |> put_req_header("idempotency-key", "suspended-point-new-key-redemption")
      |> post("/api/v1/polos/#{fixture.polo_slug}/redemptions", %{"grant" => grant})

    assert json_response(denied, 401) == %{"errors" => %{"detail" => "Unauthorized"}}

    assert %{"data" => %{"status" => "active", "revision" => 4}} =
             transition(
               conn,
               fixture,
               admin_token,
               "validation-point-reactivate-after-key-replacement",
               "reactivate",
               "Novo equipamento e nova chave instalados"
             )

    assert %{"data" => %{"validation_point_id" => validation_point_id}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Validation #{replacement_secret}")
             |> put_req_header("idempotency-key", "reactivated-point-new-key-redemption")
             |> post("/api/v1/polos/#{fixture.polo_slug}/redemptions", %{"grant" => grant})
             |> json_response(201)

    assert validation_point_id == fixture.ids.validation_point

    assert %{rows: [["expired", "active", "active", 4]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 min(credential.status) FILTER (WHERE credential.version = 1),
                 min(credential.status) FILTER (WHERE credential.version = 2),
                 point.status,
                 point.revision
               FROM validation_points AS point
               JOIN validation_credentials AS credential
                 ON credential.polo_id = point.polo_id
                AND credential.validation_point_id = point.id
               WHERE point.id = $1
               GROUP BY point.status, point.revision
               """,
               [fixture.ids.validation_point]
             )
  end

  test "an exact retry replays one observable transition without leaking its reason", %{
    conn: conn
  } do
    {validation_secret, validation_digest} = validation_material()
    fixture = RedemptionsFixtures.create!(validation_credential_secret: validation_secret)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    reason = "Terminal isolado após divergência operacional"

    first =
      transition(
        conn,
        fixture,
        admin_token,
        "validation-point-observable-suspension",
        "suspend",
        reason
      )

    replayed =
      transition(
        conn,
        fixture,
        admin_token,
        "validation-point-observable-suspension",
        "suspend",
        reason
      )

    assert replayed == first

    assert {:ok, :verified} =
             Repo.transact_in_polo(admin_scope, fn repo ->
               event =
                 repo.one!(
                   from(event in DomainEvent,
                     where:
                       event.aggregate_type == "validation_point" and
                         event.aggregate_id == ^fixture.ids.validation_point and
                         event.event_type == "validation_point.suspended"
                   )
                 )

               audit =
                 repo.one!(
                   from(audit in TenantEvent,
                     where:
                       audit.resource_id == ^fixture.ids.validation_point and
                         audit.action == "validation_point.suspended"
                   )
                 )

               outbox = repo.get_by!(OutboxMessage, domain_event_id: event.id)

               key =
                 repo.one!(
                   from(key in Key,
                     where:
                       key.scope == "redemptions.transition_validation_point" and
                         key.idempotency_key == "validation-point-observable-suspension"
                   )
                 )

               assert event.aggregate_version == 2
               assert outbox.topic == "redemptions.validation_points.suspended"
               assert outbox.message_key == fixture.ids.validation_point
               assert audit.metadata["reason"] == reason
               assert key.resource_id == fixture.ids.validation_point
               assert key.response_status == 200

               public_evidence =
                 inspect([
                   first,
                   event.payload,
                   event.metadata,
                   outbox.payload,
                   key.response_body
                 ])

               refute public_evidence =~ reason
               refute public_evidence =~ validation_secret
               refute public_evidence =~ validation_digest

               {:ok, :verified}
             end)
  end

  test "retirement is terminal and revokes the current credential atomically", %{conn: conn} do
    {validation_secret, _validation_digest} = validation_material()
    fixture = RedemptionsFixtures.create!(validation_credential_secret: validation_secret)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    grant = issue_grant!(conn, fixture)

    assert %{
             "data" => %{
               "validation_point_id" => validation_point_id,
               "action" => "retire",
               "previous_status" => "active",
               "status" => "retired",
               "revision" => 2
             }
           } =
             transition(
               conn,
               fixture,
               admin_token,
               "validation-point-retirement-001",
               "retire",
               "Terminal removido definitivamente do estabelecimento"
             )

    assert validation_point_id == fixture.ids.validation_point

    denied =
      conn
      |> recycle()
      |> put_req_header("authorization", "Validation #{validation_secret}")
      |> put_req_header("idempotency-key", "retired-point-redemption")
      |> post("/api/v1/polos/#{fixture.polo_slug}/redemptions", %{"grant" => grant})

    assert json_response(denied, 401) == %{"errors" => %{"detail" => "Unauthorized"}}

    revocation_path =
      "/api/v1/polos/#{fixture.polo_slug}/backoffice/validation-credentials/" <>
        "#{fixture.ids.validation_credential}/revocations"

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "retired-point-credential-revocation")
           |> post(revocation_path, %{})
           |> json_response(409) == %{
             "errors" => %{
               "code" => "validation_credential_revoked",
               "detail" => "Conflict"
             }
           }
  end

  test "credential rotation and point lifecycle share one monotonic event revision", %{conn: conn} do
    {validation_secret, _validation_digest} = validation_material()
    fixture = RedemptionsFixtures.create!(validation_credential_secret: validation_secret)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    {_replacement_secret, replacement_digest} = validation_material()

    rotation_path =
      "/api/v1/polos/#{fixture.polo_slug}/backoffice/validation-credentials/" <>
        "#{fixture.ids.validation_credential}/rotations"

    assert %{"data" => %{"credential" => %{"version" => 2}}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> put_req_header("idempotency-key", "rotation-before-point-suspension")
             |> post(rotation_path, %{
               "credential" => %{
                 "secret_sha256" => replacement_digest,
                 "expires_at" => fixture.now |> DateTime.add(90, :day) |> DateTime.to_iso8601()
               }
             })
             |> json_response(201)

    assert %{"data" => %{"status" => "suspended", "revision" => 3}} =
             transition(
               conn,
               fixture,
               admin_token,
               "suspension-after-credential-rotation",
               "suspend",
               "Pausa operacional após troca programada"
             )
  end

  test "an invalid lifecycle transition is one stable audited conflict", %{conn: conn} do
    {validation_secret, _validation_digest} = validation_material()
    fixture = RedemptionsFixtures.create!(validation_credential_secret: validation_secret)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)

    assert %{"data" => %{"status" => "suspended", "revision" => 2}} =
             transition(
               conn,
               fixture,
               admin_token,
               "validation-point-initial-suspension",
               "suspend",
               "Primeira suspensão operacional"
             )

    expected_error = %{
      "errors" => %{
        "code" => "invalid_validation_point_transition",
        "detail" => "Conflict"
      }
    }

    for _attempt <- 1..2 do
      assert transition_conflict(
               conn,
               fixture,
               admin_token,
               "validation-point-duplicate-suspension",
               "suspend",
               "Suspensão repetida por engano"
             ) == expected_error
    end

    assert %{rows: [[1, 1, 2, 1]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 (SELECT count(*)
                    FROM tenant_idempotency_keys
                   WHERE scope = 'redemptions.transition_validation_point'
                     AND idempotency_key = 'validation-point-duplicate-suspension'
                     AND status = 'failed'
                     AND response_status = 409),
                 (SELECT count(*)
                    FROM tenant_audit_events
                   WHERE action = 'validation_point.transition_rejected'
                     AND metadata->>'reason' = 'invalid_validation_point_transition'),
                 point.revision,
                 (SELECT count(*)
                    FROM domain_events
                   WHERE aggregate_type = 'validation_point'
                     AND aggregate_id = point.id
                     AND event_type = 'validation_point.suspended')
               FROM validation_points AS point
               WHERE point.id = $1
               """,
               [fixture.ids.validation_point]
             )
  end

  test "a suspended point cannot reactivate an explicitly revoked credential", %{conn: conn} do
    {validation_secret, _validation_digest} = validation_material()
    fixture = RedemptionsFixtures.create!(validation_credential_secret: validation_secret)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)

    assert %{"data" => %{"status" => "suspended"}} =
             transition(
               conn,
               fixture,
               admin_token,
               "validation-point-suspend-before-revocation",
               "suspend",
               "Terminal comprometido em análise"
             )

    revocation_path =
      "/api/v1/polos/#{fixture.polo_slug}/backoffice/validation-credentials/" <>
        "#{fixture.ids.validation_credential}/revocations"

    assert %{"data" => %{"credential" => %{"status" => "revoked"}}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> put_req_header("idempotency-key", "suspended-point-credential-revocation")
             |> post(revocation_path, %{})
             |> json_response(200)

    assert transition_conflict(
             conn,
             fixture,
             admin_token,
             "validation-point-reactivation-with-revoked-credential",
             "reactivate",
             "Tentativa de retorno sem credencial nova"
           ) == %{
             "errors" => %{
               "code" => "validation_credential_revoked",
               "detail" => "Conflict"
             }
           }

    assert %{rows: [["suspended", 2]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               "SELECT status, revision FROM validation_points WHERE id = $1",
               [fixture.ids.validation_point]
             )
  end

  test "reactivation requires an active place participation and replays one stable conflict", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)

    assert %{"data" => %{"status" => "suspended"}} =
             transition(
               conn,
               fixture,
               admin_token,
               "validation-point-suspend-before-place-exit",
               "suspend",
               "Pausa antes do encerramento da parceria"
             )

    RedemptionsFixtures.scoped_query!(
      fixture,
      "UPDATE polo_places SET status = 'suspended' WHERE id = $1",
      [fixture.ids.polo_place]
    )

    expected_error = %{
      "errors" => %{
        "code" => "validation_point_unavailable",
        "detail" => "Conflict"
      }
    }

    for _attempt <- 1..2 do
      assert transition_conflict(
               conn,
               fixture,
               admin_token,
               "validation-point-reactivation-with-inactive-place",
               "reactivate",
               "Tentativa de retorno após o fim da parceria"
             ) == expected_error
    end

    assert %{rows: [["suspended", 2, 1, 1]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 point.status,
                 point.revision,
                 (SELECT count(*)
                    FROM tenant_idempotency_keys
                   WHERE scope = 'redemptions.transition_validation_point'
                     AND idempotency_key = 'validation-point-reactivation-with-inactive-place'
                     AND status = 'failed'
                     AND response_status = 409),
                 (SELECT count(*)
                    FROM tenant_audit_events
                   WHERE action = 'validation_point.transition_rejected'
                     AND metadata->>'reason' = 'validation_point_unavailable')
               FROM validation_points AS point
               WHERE point.id = $1
               """,
               [fixture.ids.validation_point]
             )
  end

  test "only an admin from the point polo can change its lifecycle", %{conn: conn} do
    authorized = RedemptionsFixtures.create!()
    other_polo = RedemptionsFixtures.create!()
    moderator_scope = ReviewsFixtures.grant_moderator!(authorized)
    moderator_token = authenticate!(moderator_scope.actor_user_id)
    other_admin_scope = ReviewsFixtures.grant_moderator!(other_polo, role_key: "admin")
    other_admin_token = authenticate!(other_admin_scope.actor_user_id)

    assert conn
           |> put_req_header("authorization", "Bearer #{moderator_token}")
           |> put_req_header("idempotency-key", "validation-point-moderator-suspension")
           |> post(lifecycle_path(authorized), %{
             "action" => "suspend",
             "reason" => "Tentativa sem privilégio administrativo"
           })
           |> json_response(403) == %{"errors" => %{"detail" => "Forbidden"}}

    cross_polo_path =
      "/api/v1/polos/#{other_polo.polo_slug}/backoffice/validation-points/" <>
        "#{authorized.ids.validation_point}/lifecycle-actions"

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{other_admin_token}")
           |> put_req_header("idempotency-key", "validation-point-cross-polo-suspension")
           |> post(cross_polo_path, %{
             "action" => "suspend",
             "reason" => "Tentativa contra ponto de outro polo"
           })
           |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}

    assert %{rows: [["active", 1, 0, 0]]} =
             RedemptionsFixtures.scoped_query!(
               authorized,
               """
               SELECT
                 status,
                 revision,
                 (SELECT count(*)
                    FROM tenant_idempotency_keys
                   WHERE scope = 'redemptions.transition_validation_point'),
                 (SELECT count(*)
                    FROM domain_events
                   WHERE event_type IN (
                     'validation_point.suspended',
                     'validation_point.reactivated',
                     'validation_point.retired'
                   ))
               FROM validation_points
               WHERE id = $1
               """,
               [authorized.ids.validation_point]
             )
  end

  test "the lifecycle route does not claim unsupported validation point kinds", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)

    RedemptionsFixtures.scoped_query!(
      fixture,
      "UPDATE validation_points SET kind = 'terminal' WHERE id = $1",
      [fixture.ids.validation_point]
    )

    assert conn
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "unsupported-point-kind-suspension")
           |> post(lifecycle_path(fixture), %{
             "action" => "suspend",
             "reason" => "Ponto fora da borda API suportada"
           })
           |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}

    assert %{rows: [["terminal", "active", 1, 0]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 kind,
                 status,
                 revision,
                 (SELECT count(*)
                    FROM tenant_idempotency_keys
                   WHERE scope = 'redemptions.transition_validation_point')
               FROM validation_points
               WHERE id = $1
               """,
               [fixture.ids.validation_point]
             )
  end

  test "invalid lifecycle input is rejected before reserving idempotency", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)

    cases = [
      {nil, "suspend", "Pausa operacional válida"},
      {"short", "suspend", "Pausa operacional válida"},
      {"validation-point-invalid-action", "archive", "Ação desconhecida"},
      {"validation-point-invalid-reason", "suspend", "x"}
    ]

    for {idempotency_key, action, reason} <- cases do
      request =
        conn
        |> recycle()
        |> put_req_header("authorization", "Bearer #{admin_token}")
        |> maybe_put_idempotency_key(idempotency_key)
        |> post(lifecycle_path(fixture), %{"action" => action, "reason" => reason})

      assert json_response(request, 422) == %{
               "errors" => %{"detail" => "Unprocessable Content"}
             }
    end

    assert %{rows: [["active", 1, 0]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 status,
                 revision,
                 (SELECT count(*)
                    FROM tenant_idempotency_keys
                   WHERE scope = 'redemptions.transition_validation_point')
               FROM validation_points
               WHERE id = $1
               """,
               [fixture.ids.validation_point]
             )
  end

  defp lifecycle_path(fixture) do
    "/api/v1/polos/#{fixture.polo_slug}/backoffice/validation-points/" <>
      "#{fixture.ids.validation_point}/lifecycle-actions"
  end

  defp transition(conn, fixture, admin_token, idempotency_key, action, reason) do
    conn
    |> recycle()
    |> put_req_header("authorization", "Bearer #{admin_token}")
    |> put_req_header("idempotency-key", idempotency_key)
    |> post(lifecycle_path(fixture), %{"action" => action, "reason" => reason})
    |> json_response(200)
  end

  defp transition_conflict(conn, fixture, admin_token, idempotency_key, action, reason) do
    conn
    |> recycle()
    |> put_req_header("authorization", "Bearer #{admin_token}")
    |> put_req_header("idempotency-key", idempotency_key)
    |> post(lifecycle_path(fixture), %{"action" => action, "reason" => reason})
    |> json_response(409)
  end

  defp maybe_put_idempotency_key(conn, nil), do: conn

  defp maybe_put_idempotency_key(conn, idempotency_key) do
    put_req_header(conn, "idempotency-key", idempotency_key)
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session.token
  end

  defp issue_grant!(conn, fixture) do
    member_token = authenticate!(fixture.ids.user)
    installation_token = random_token()

    assert %{"data" => %{"id" => device_installation_id}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{member_token}")
             |> post("/api/v1/polos/#{fixture.polo_slug}/me/redemption-devices", %{
               "access_contract_id" => fixture.ids.access_contract,
               "installation_token" => installation_token,
               "platform" => "android"
             })
             |> json_response(201)

    assert %{"data" => %{"grant" => grant}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{member_token}")
             |> post("/api/v1/polos/#{fixture.polo_slug}/me/redemption-grants", %{
               "entitlement_allocation_id" => fixture.ids.entitlement_allocation,
               "installation_token" => installation_token
             })
             |> json_response(201)

    assert is_binary(device_installation_id)
    grant
  end

  defp validation_material do
    secret = :crypto.strong_rand_bytes(32)

    {
      Base.url_encode64(secret, padding: false),
      Base.url_encode64(:crypto.hash(:sha256, secret), padding: false)
    }
  end

  defp random_token do
    Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end
end
