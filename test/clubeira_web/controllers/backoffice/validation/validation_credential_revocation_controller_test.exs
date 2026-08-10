defmodule ClubeiraWeb.Backoffice.ValidationCredentialRevocationControllerTest do
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

  test "a polo admin revokes the current credential and blocks its authentication", %{conn: conn} do
    {validation_secret, validation_digest} = validation_material()
    fixture = RedemptionsFixtures.create!(validation_credential_secret: validation_secret)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    grant = issue_grant!(conn, fixture)

    response =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{admin_token}")
      |> put_req_header("idempotency-key", "validation-credential-revocation-001")
      |> post(revocation_path(fixture), %{})
      |> json_response(200)

    assert %{
             "data" => %{
               "validation_point_id" => validation_point_id,
               "credential" => %{
                 "id" => credential_id,
                 "version" => 1,
                 "kind" => "api_key",
                 "status" => "revoked",
                 "valid_from" => valid_from,
                 "valid_until" => valid_until
               }
             }
           } = response

    assert validation_point_id == fixture.ids.validation_point
    assert credential_id == fixture.ids.validation_credential
    assert {:ok, _valid_from, 0} = DateTime.from_iso8601(valid_from)
    assert {:ok, _valid_until, 0} = DateTime.from_iso8601(valid_until)
    refute inspect(response) =~ validation_secret
    refute inspect(response) =~ validation_digest

    denied =
      conn
      |> recycle()
      |> put_req_header("authorization", "Validation #{validation_secret}")
      |> put_req_header("idempotency-key", "revoked-credential-redemption")
      |> post("/api/v1/polos/#{fixture.polo_slug}/redemptions", %{"grant" => grant})

    assert json_response(denied, 401) == %{"errors" => %{"detail" => "Unauthorized"}}
    assert get_resp_header(denied, "www-authenticate") != []
  end

  test "an exact retry replays one observable revocation without credential material", %{
    conn: conn
  } do
    {validation_secret, validation_digest} = validation_material()
    fixture = RedemptionsFixtures.create!(validation_credential_secret: validation_secret)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)

    first =
      revoke(
        conn,
        fixture,
        admin_token,
        "validation-credential-observable-revocation"
      )

    replayed =
      revoke(
        conn,
        fixture,
        admin_token,
        "validation-credential-observable-revocation"
      )

    assert replayed == first

    assert {:ok, :verified} =
             Repo.transact_in_polo(admin_scope, fn repo ->
               event =
                 repo.one!(
                   from(event in DomainEvent,
                     where:
                       event.aggregate_type == "validation_credential" and
                         event.aggregate_id == ^fixture.ids.validation_credential and
                         event.event_type == "validation_credential.revoked"
                   )
                 )

               audit =
                 repo.one!(
                   from(audit in TenantEvent,
                     where:
                       audit.resource_id == ^fixture.ids.validation_credential and
                         audit.action == "validation_credential.revoked"
                   )
                 )

               outbox = repo.get_by!(OutboxMessage, domain_event_id: event.id)

               key =
                 repo.one!(
                   from(key in Key,
                     where:
                       key.scope == "redemptions.revoke_validation_credential" and
                         key.idempotency_key == "validation-credential-observable-revocation"
                   )
                 )

               assert event.aggregate_version == 1
               assert outbox.topic == "redemptions.validation_credentials.revoked"
               assert outbox.message_key == fixture.ids.validation_credential
               assert key.resource_id == fixture.ids.validation_credential
               assert key.response_status == 200

               public_evidence =
                 inspect([
                   first,
                   event.payload,
                   event.metadata,
                   audit.metadata,
                   outbox.payload,
                   key.response_body
                 ])

               refute public_evidence =~ validation_secret
               refute public_evidence =~ validation_digest

               {:ok, :verified}
             end)
  end

  test "an explicitly revoked credential cannot be revived by the rotation endpoint", %{
    conn: conn
  } do
    {validation_secret, _validation_digest} = validation_material()
    fixture = RedemptionsFixtures.create!(validation_credential_secret: validation_secret)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    {_replacement_secret, replacement_digest} = validation_material()

    assert %{"data" => %{"credential" => %{"status" => "revoked"}}} =
             revoke(conn, fixture, admin_token, "validation-credential-terminal-revocation")

    expected_error = %{
      "errors" => %{
        "code" => "validation_credential_revoked",
        "detail" => "Conflict"
      }
    }

    assert rotate_revoked(conn, fixture, admin_token, replacement_digest) == expected_error
    assert rotate_revoked(conn, fixture, admin_token, replacement_digest) == expected_error

    assert %{rows: [[1, "revoked"]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT max(version), min(status)
               FROM validation_credentials
               WHERE validation_point_id = $1
               """,
               [fixture.ids.validation_point]
             )

    assert {:ok, :verified} =
             Repo.transact_in_polo(admin_scope, fn repo ->
               key =
                 repo.one!(
                   from(key in Key,
                     where:
                       key.scope == "redemptions.rotate_validation_credential" and
                         key.idempotency_key == "revoked-credential-cannot-rotate"
                   )
                 )

               assert key.status == "failed"
               assert key.response_status == 409
               assert key.response_body == %{"reason" => "validation_credential_revoked"}

               rejected_audits =
                 repo.aggregate(
                   from(audit in TenantEvent,
                     where:
                       audit.resource_id == ^fixture.ids.validation_credential and
                         audit.action == "validation_credential.rotation_rejected"
                   ),
                   :count
                 )

               assert rejected_audits == 1
               {:ok, :verified}
             end)
  end

  test "a new request against an already revoked credential is one stable rejection", %{
    conn: conn
  } do
    {validation_secret, _validation_digest} = validation_material()
    fixture = RedemptionsFixtures.create!(validation_credential_secret: validation_secret)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)

    assert %{"data" => %{"credential" => %{"status" => "revoked"}}} =
             revoke(conn, fixture, admin_token, "validation-credential-initial-revocation")

    expected_error = %{
      "errors" => %{
        "code" => "validation_credential_revoked",
        "detail" => "Conflict"
      }
    }

    for _attempt <- 1..2 do
      assert revocation_conflict(
               conn,
               fixture,
               admin_token,
               "validation-credential-already-revoked"
             ) == expected_error
    end

    assert %{rows: [[1, 1, 1]]} =
             RedemptionsFixtures.scoped_query!(fixture, """
             SELECT
               (SELECT count(*)
                  FROM tenant_idempotency_keys
                 WHERE scope = 'redemptions.revoke_validation_credential'
                   AND idempotency_key = 'validation-credential-already-revoked'
                   AND status = 'failed'
                   AND response_status = 409),
               (SELECT count(*)
                  FROM tenant_audit_events
                 WHERE action = 'validation_credential.revocation_rejected'
                   AND metadata->>'reason' = 'validation_credential_revoked'),
               (SELECT count(*)
                  FROM domain_events
                 WHERE event_type = 'validation_credential.revoked')
             """)
  end

  test "a stale credential target is one audited rejection and leaves its successor active", %{
    conn: conn
  } do
    {original_secret, _original_digest} = validation_material()
    fixture = RedemptionsFixtures.create!(validation_credential_secret: original_secret)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    {_current_secret, current_digest} = validation_material()

    assert %{"data" => %{"credential" => %{"version" => 2, "status" => "active"}}} =
             rotate_current(
               conn,
               fixture,
               admin_token,
               current_digest,
               "validation-credential-before-stale-revocation"
             )

    expected_error = %{
      "errors" => %{
        "code" => "validation_credential_stale",
        "detail" => "Conflict"
      }
    }

    for _attempt <- 1..2 do
      assert revocation_conflict(
               conn,
               fixture,
               admin_token,
               "validation-credential-stale-revocation"
             ) == expected_error
    end

    assert %{rows: [[1, 1, 2, 1]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 (SELECT count(*)
                    FROM tenant_idempotency_keys
                   WHERE scope = 'redemptions.revoke_validation_credential'
                     AND idempotency_key = 'validation-credential-stale-revocation'
                     AND status = 'failed'
                     AND response_status = 409),
                 (SELECT count(*)
                    FROM tenant_audit_events
                   WHERE action = 'validation_credential.revocation_rejected'
                     AND metadata->>'reason' = 'validation_credential_stale'),
                 max(version),
                 count(*) FILTER (WHERE status = 'active')
               FROM validation_credentials
               WHERE validation_point_id = $1
               """,
               [fixture.ids.validation_point]
             )
  end

  test "only an admin from the credential polo can revoke it", %{conn: conn} do
    {validation_secret, _validation_digest} = validation_material()
    authorized = RedemptionsFixtures.create!(validation_credential_secret: validation_secret)
    other_polo = RedemptionsFixtures.create!()
    moderator_scope = ReviewsFixtures.grant_moderator!(authorized)
    moderator_token = authenticate!(moderator_scope.actor_user_id)
    other_admin_scope = ReviewsFixtures.grant_moderator!(other_polo, role_key: "admin")
    other_admin_token = authenticate!(other_admin_scope.actor_user_id)

    assert conn
           |> put_req_header("authorization", "Bearer #{moderator_token}")
           |> put_req_header("idempotency-key", "validation-credential-moderator-revocation")
           |> post(revocation_path(authorized), %{})
           |> json_response(403) == %{"errors" => %{"detail" => "Forbidden"}}

    cross_polo_path =
      "/api/v1/polos/#{other_polo.polo_slug}/backoffice/validation-credentials/" <>
        "#{authorized.ids.validation_credential}/revocations"

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{other_admin_token}")
           |> put_req_header("idempotency-key", "validation-credential-cross-polo-revocation")
           |> post(cross_polo_path, %{})
           |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}

    assert %{rows: [["active", 0, 0]]} =
             RedemptionsFixtures.scoped_query!(
               authorized,
               """
               SELECT
                 status,
                 (SELECT count(*)
                    FROM tenant_idempotency_keys
                   WHERE scope = 'redemptions.revoke_validation_credential'),
                 (SELECT count(*)
                    FROM domain_events
                   WHERE event_type = 'validation_credential.revoked')
               FROM validation_credentials
               WHERE id = $1
               """,
               [authorized.ids.validation_credential]
             )
  end

  test "an idempotency key is required and validated before credential mutation", %{conn: conn} do
    {validation_secret, _validation_digest} = validation_material()
    fixture = RedemptionsFixtures.create!(validation_credential_secret: validation_secret)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)

    for idempotency_key <- [nil, "short", "invalid key with spaces"] do
      request =
        conn
        |> recycle()
        |> put_req_header("authorization", "Bearer #{admin_token}")
        |> maybe_put_idempotency_key(idempotency_key)
        |> post(revocation_path(fixture), %{})

      assert json_response(request, 422) == %{
               "errors" => %{"detail" => "Unprocessable Content"}
             }
    end

    assert %{rows: [["active", 0]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 status,
                 (SELECT count(*)
                    FROM tenant_idempotency_keys
                   WHERE scope = 'redemptions.revoke_validation_credential')
               FROM validation_credentials
               WHERE id = $1
               """,
               [fixture.ids.validation_credential]
             )
  end

  test "an admin can revoke the credential after its validation point is suspended", %{conn: conn} do
    {validation_secret, _validation_digest} = validation_material()
    fixture = RedemptionsFixtures.create!(validation_credential_secret: validation_secret)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)

    RedemptionsFixtures.scoped_query!(
      fixture,
      "UPDATE validation_points SET status = 'suspended' WHERE id = $1",
      [fixture.ids.validation_point]
    )

    assert %{
             "data" => %{
               "validation_point_id" => validation_point_id,
               "credential" => %{"status" => "revoked"}
             }
           } =
             revoke(
               conn,
               fixture,
               admin_token,
               "validation-credential-suspended-point-revocation"
             )

    assert validation_point_id == fixture.ids.validation_point

    assert %{rows: [["suspended", "revoked"]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT point.status, credential.status
               FROM validation_points AS point
               JOIN validation_credentials AS credential
                 ON credential.polo_id = point.polo_id
                AND credential.validation_point_id = point.id
               WHERE point.id = $1
               """,
               [fixture.ids.validation_point]
             )
  end

  defp revocation_path(fixture) do
    "/api/v1/polos/#{fixture.polo_slug}/backoffice/validation-credentials/" <>
      "#{fixture.ids.validation_credential}/revocations"
  end

  defp revoke(conn, fixture, admin_token, idempotency_key) do
    conn
    |> recycle()
    |> put_req_header("authorization", "Bearer #{admin_token}")
    |> put_req_header("idempotency-key", idempotency_key)
    |> post(revocation_path(fixture), %{})
    |> json_response(200)
  end

  defp revocation_conflict(conn, fixture, admin_token, idempotency_key) do
    conn
    |> recycle()
    |> put_req_header("authorization", "Bearer #{admin_token}")
    |> put_req_header("idempotency-key", idempotency_key)
    |> post(revocation_path(fixture), %{})
    |> json_response(409)
  end

  defp maybe_put_idempotency_key(conn, nil), do: conn

  defp maybe_put_idempotency_key(conn, idempotency_key) do
    put_req_header(conn, "idempotency-key", idempotency_key)
  end

  defp rotate_revoked(conn, fixture, admin_token, replacement_digest) do
    rotation_path =
      "/api/v1/polos/#{fixture.polo_slug}/backoffice/validation-credentials/" <>
        "#{fixture.ids.validation_credential}/rotations"

    conn
    |> recycle()
    |> put_req_header("authorization", "Bearer #{admin_token}")
    |> put_req_header("idempotency-key", "revoked-credential-cannot-rotate")
    |> post(rotation_path, %{
      "credential" => %{
        "secret_sha256" => replacement_digest,
        "expires_at" => fixture.now |> DateTime.add(90, :day) |> DateTime.to_iso8601()
      }
    })
    |> json_response(409)
  end

  defp rotate_current(conn, fixture, admin_token, replacement_digest, idempotency_key) do
    rotation_path =
      "/api/v1/polos/#{fixture.polo_slug}/backoffice/validation-credentials/" <>
        "#{fixture.ids.validation_credential}/rotations"

    conn
    |> recycle()
    |> put_req_header("authorization", "Bearer #{admin_token}")
    |> put_req_header("idempotency-key", idempotency_key)
    |> post(rotation_path, %{
      "credential" => %{
        "secret_sha256" => replacement_digest,
        "expires_at" => fixture.now |> DateTime.add(90, :day) |> DateTime.to_iso8601()
      }
    })
    |> json_response(201)
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
