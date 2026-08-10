defmodule ClubeiraWeb.Backoffice.ValidationCredentialRotationControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  import Ecto.Query

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Audit.TenantEvent
  alias Clubeira.Events.DomainEvent
  alias Clubeira.Events.OutboxMessage
  alias Clubeira.Idempotency.Key
  alias Clubeira.Redemptions.ValidationCredential
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  @password "uma-senha-de-administracao-forte"

  test "a polo admin rotates the current credential and cuts over redemption authentication", %{
    conn: conn
  } do
    {old_secret, _old_digest} = validation_material()
    fixture = RedemptionsFixtures.create!(validation_credential_secret: old_secret)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    {new_secret, new_digest} = validation_material()
    expires_at = fixture.now |> DateTime.add(90, :day) |> DateTime.to_iso8601()

    assert %{
             "data" => %{
               "validation_point_id" => validation_point_id,
               "replaced_credential_id" => replaced_credential_id,
               "credential" => %{
                 "id" => new_credential_id,
                 "version" => 2,
                 "kind" => "api_key",
                 "status" => "active",
                 "valid_from" => valid_from,
                 "expires_at" => ^expires_at
               }
             }
           } =
             conn
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> put_req_header("idempotency-key", "validation-credential-rotation-001")
             |> post(rotation_path(fixture), %{
               "credential" => %{
                 "secret_sha256" => new_digest,
                 "expires_at" => expires_at
               }
             })
             |> json_response(201)

    assert validation_point_id == fixture.ids.validation_point
    assert replaced_credential_id == fixture.ids.validation_credential
    assert {:ok, ^new_credential_id} = Ecto.UUID.cast(new_credential_id)
    assert {:ok, _valid_from, 0} = DateTime.from_iso8601(valid_from)

    assert %{
             "data" => [
               %{
                 "id" => ^validation_point_id,
                 "credential" => %{
                   "id" => ^new_credential_id,
                   "version" => 2,
                   "status" => "active"
                 }
               }
             ]
           } =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(
               "/api/v1/polos/#{fixture.polo_slug}/backoffice/validation-points?place_id=#{fixture.ids.place}"
             )
             |> json_response(200)

    grant = issue_grant!(conn, fixture)

    old_credential_response =
      conn
      |> recycle()
      |> put_req_header("authorization", "Validation #{old_secret}")
      |> put_req_header("idempotency-key", "rotated-old-credential-redemption")
      |> post("/api/v1/polos/#{fixture.polo_slug}/redemptions", %{"grant" => grant})

    assert json_response(old_credential_response, 401) == %{
             "errors" => %{"detail" => "Unauthorized"}
           }

    assert %{
             "data" => %{
               "validation_point_id" => ^validation_point_id
             }
           } =
             conn
             |> recycle()
             |> put_req_header("authorization", "Validation #{new_secret}")
             |> put_req_header("idempotency-key", "rotated-new-credential-redemption")
             |> post("/api/v1/polos/#{fixture.polo_slug}/redemptions", %{"grant" => grant})
             |> json_response(201)
  end

  test "a duplicate digest is a stable conflict that preserves the current credential", %{
    conn: conn
  } do
    {current_secret, current_digest} = validation_material()
    fixture = RedemptionsFixtures.create!(validation_credential_secret: current_secret)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)

    request = %{
      "credential" => %{
        "secret_sha256" => current_digest,
        "expires_at" => fixture.now |> DateTime.add(90, :day) |> DateTime.to_iso8601()
      }
    }

    for _attempt <- 1..2 do
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> put_req_header("idempotency-key", "validation-credential-duplicate-digest")
             |> post(rotation_path(fixture), request)
             |> json_response(409) == %{
               "errors" => %{
                 "code" => "validation_credential_conflict",
                 "detail" => "Conflict"
               }
             }
    end

    grant = issue_grant!(conn, fixture)

    assert %{"data" => %{"validation_point_id" => validation_point_id}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Validation #{current_secret}")
             |> put_req_header("idempotency-key", "preserved-current-credential-redemption")
             |> post("/api/v1/polos/#{fixture.polo_slug}/redemptions", %{"grant" => grant})
             |> json_response(201)

    assert validation_point_id == fixture.ids.validation_point
  end

  test "a stale target is one audited conflict and preserves the current credential", %{
    conn: conn
  } do
    {original_secret, _original_digest} = validation_material()
    fixture = RedemptionsFixtures.create!(validation_credential_secret: original_secret)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    {current_secret, current_digest} = validation_material()
    {_discarded_secret, discarded_digest} = validation_material()
    expires_at = fixture.now |> DateTime.add(90, :day) |> DateTime.to_iso8601()

    assert %{"data" => %{"credential" => %{"version" => 2}}} =
             rotate(
               conn,
               fixture,
               admin_token,
               "validation-credential-first-rotation",
               current_digest,
               expires_at
             )

    stale_request = %{
      "credential" => %{
        "secret_sha256" => discarded_digest,
        "expires_at" => expires_at
      }
    }

    for _attempt <- 1..2 do
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> put_req_header("idempotency-key", "validation-credential-stale-rotation")
             |> post(rotation_path(fixture), stale_request)
             |> json_response(409) == %{
               "errors" => %{
                 "code" => "validation_credential_stale",
                 "detail" => "Conflict"
               }
             }
    end

    assert %{rows: [[1, 1, 2]]} =
             RedemptionsFixtures.scoped_query!(fixture, """
             SELECT
               (SELECT count(*)
                  FROM tenant_idempotency_keys
                 WHERE scope = 'redemptions.rotate_validation_credential'
                   AND idempotency_key = 'validation-credential-stale-rotation'
                   AND status = 'failed'
                   AND response_status = 409),
               (SELECT count(*)
                  FROM tenant_audit_events
                 WHERE action = 'validation_credential.rotation_rejected'
                   AND metadata->>'reason' = 'validation_credential_stale'),
               (SELECT max(version) FROM validation_credentials)
             """)

    grant = issue_grant!(conn, fixture)

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Validation #{current_secret}")
           |> put_req_header("idempotency-key", "stale-preserved-current-redemption")
           |> post("/api/v1/polos/#{fixture.polo_slug}/redemptions", %{"grant" => grant})
           |> json_response(201)
  end

  test "an exact retry replays one observable rotation without credential material", %{conn: conn} do
    {original_secret, _original_digest} = validation_material()
    fixture = RedemptionsFixtures.create!(validation_credential_secret: original_secret)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    {new_secret, new_digest} = validation_material()
    expires_at = fixture.now |> DateTime.add(90, :day) |> DateTime.to_iso8601()

    first =
      rotate(
        conn,
        fixture,
        admin_token,
        "validation-credential-observable-retry",
        new_digest,
        expires_at
      )

    replayed =
      rotate(
        conn,
        fixture,
        admin_token,
        "validation-credential-observable-retry",
        new_digest,
        expires_at
      )

    assert replayed == first
    new_credential_id = get_in(first, ["data", "credential", "id"])

    assert {:ok, :verified} =
             Repo.transact_in_polo(admin_scope, fn repo ->
               credentials =
                 repo.all(
                   from(credential in ValidationCredential,
                     where: credential.validation_point_id == ^fixture.ids.validation_point,
                     order_by: credential.version
                   )
                 )

               assert [replaced, current] = credentials
               assert replaced.status == "revoked"
               assert current.id == new_credential_id
               assert current.version == 2
               assert current.status == "active"
               assert replaced.valid_during.upper == current.valid_during.lower

               event =
                 repo.one!(
                   from(event in DomainEvent,
                     where:
                       event.aggregate_id == ^fixture.ids.validation_point and
                         event.event_type == "validation_credential.rotated"
                   )
                 )

               audit =
                 repo.one!(
                   from(audit in TenantEvent,
                     where:
                       audit.resource_id == ^new_credential_id and
                         audit.action == "validation_credential.rotated"
                   )
                 )

               outbox = repo.get_by!(OutboxMessage, domain_event_id: event.id)

               key =
                 repo.one!(
                   from(key in Key,
                     where:
                       key.scope == "redemptions.rotate_validation_credential" and
                         key.idempotency_key == "validation-credential-observable-retry"
                   )
                 )

               assert event.aggregate_version == 2
               assert event.aggregate_id == fixture.ids.validation_point
               assert audit.resource_id == new_credential_id
               assert outbox.topic == "redemptions.validation_credentials.rotated"
               assert outbox.message_key == fixture.ids.validation_point
               assert key.resource_id == new_credential_id
               assert key.response_status == 201

               public_evidence =
                 inspect([
                   first,
                   event.payload,
                   event.metadata,
                   audit.metadata,
                   outbox.payload,
                   key.response_body
                 ])

               refute public_evidence =~ new_secret
               refute public_evidence =~ new_digest

               {:ok, :verified}
             end)
  end

  test "an expired current credential can be renewed without rewriting its history", %{conn: conn} do
    {expired_secret, _expired_digest} = validation_material()
    fixture = RedemptionsFixtures.create!(validation_credential_secret: expired_secret)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    {renewed_secret, renewed_digest} = validation_material()
    expires_at = fixture.now |> DateTime.add(90, :day) |> DateTime.to_iso8601()

    RedemptionsFixtures.scoped_query!(
      fixture,
      """
      UPDATE validation_credentials
         SET valid_during = tstzrange(
           statement_timestamp() - interval '1 day',
           statement_timestamp() - interval '1 second',
           '[)'
         )
       WHERE id = $1
      """,
      [fixture.ids.validation_credential]
    )

    assert %{
             "data" => %{
               "replaced_credential_id" => replaced_credential_id,
               "credential" => %{"version" => 2, "status" => "active"}
             }
           } =
             rotate(
               conn,
               fixture,
               admin_token,
               "validation-credential-expired-renewal",
               renewed_digest,
               expires_at
             )

    assert replaced_credential_id == fixture.ids.validation_credential

    assert %{rows: [["expired", 1]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 (SELECT status FROM validation_credentials WHERE id = $1),
                 (SELECT count(*)
                    FROM validation_credentials
                   WHERE validation_point_id = $2
                     AND version = 2
                     AND status = 'active')
               """,
               [fixture.ids.validation_credential, fixture.ids.validation_point]
             )

    grant = issue_grant!(conn, fixture)

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Validation #{renewed_secret}")
           |> put_req_header("idempotency-key", "renewed-credential-redemption")
           |> post("/api/v1/polos/#{fixture.polo_slug}/redemptions", %{"grant" => grant})
           |> json_response(201)
  end

  test "only an admin from the credential polo can rotate it", %{conn: conn} do
    {credential_secret, _credential_digest} = validation_material()
    authorized = RedemptionsFixtures.create!(validation_credential_secret: credential_secret)
    other_polo = RedemptionsFixtures.create!()
    moderator_scope = ReviewsFixtures.grant_moderator!(authorized)
    moderator_token = authenticate!(moderator_scope.actor_user_id)
    other_admin_scope = ReviewsFixtures.grant_moderator!(other_polo, role_key: "admin")
    other_admin_token = authenticate!(other_admin_scope.actor_user_id)
    {_new_secret, new_digest} = validation_material()
    expires_at = authorized.now |> DateTime.add(90, :day) |> DateTime.to_iso8601()

    request = %{
      "credential" => %{"secret_sha256" => new_digest, "expires_at" => expires_at}
    }

    assert conn
           |> put_req_header("authorization", "Bearer #{moderator_token}")
           |> put_req_header("idempotency-key", "validation-credential-moderator-denied")
           |> post(rotation_path(authorized), request)
           |> json_response(403) == %{"errors" => %{"detail" => "Forbidden"}}

    cross_polo_path =
      "/api/v1/polos/#{other_polo.polo_slug}/backoffice/validation-credentials/" <>
        "#{authorized.ids.validation_credential}/rotations"

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{other_admin_token}")
           |> put_req_header("idempotency-key", "validation-credential-cross-polo-denied")
           |> post(cross_polo_path, request)
           |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}

    assert %{rows: [[1, "active", 0]]} =
             RedemptionsFixtures.scoped_query!(
               authorized,
               """
               SELECT
                 count(*),
                 min(status),
                 (SELECT count(*)
                    FROM tenant_idempotency_keys
                   WHERE scope = 'redemptions.rotate_validation_credential')
               FROM validation_credentials
               WHERE validation_point_id = $1
               """,
               [authorized.ids.validation_point]
             )
  end

  test "unsafe rotation material is rejected before any credential mutation", %{conn: conn} do
    {current_secret, _current_digest} = validation_material()
    fixture = RedemptionsFixtures.create!(validation_credential_secret: current_secret)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    {_new_secret, valid_digest} = validation_material()
    valid_expiration = fixture.now |> DateTime.add(90, :day) |> DateTime.to_iso8601()

    cases = [
      {"validation-credential-malformed-digest", "not-a-sha256-digest", valid_expiration},
      {"validation-credential-expired-input", valid_digest,
       fixture.now |> DateTime.add(-1, :day) |> DateTime.to_iso8601()},
      {"validation-credential-too-long", valid_digest,
       fixture.now |> DateTime.add(366, :day) |> DateTime.to_iso8601()},
      {nil, valid_digest, valid_expiration}
    ]

    for {idempotency_key, digest, expires_at} <- cases do
      request =
        conn
        |> recycle()
        |> put_req_header("authorization", "Bearer #{admin_token}")
        |> maybe_put_idempotency_key(idempotency_key)
        |> post(rotation_path(fixture), %{
          "credential" => %{"secret_sha256" => digest, "expires_at" => expires_at}
        })

      assert json_response(request, 422) == %{
               "errors" => %{"detail" => "Unprocessable Content"}
             }
    end

    assert %{rows: [[1, "active", 0]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 count(*),
                 min(status),
                 (SELECT count(*)
                    FROM tenant_idempotency_keys
                   WHERE scope = 'redemptions.rotate_validation_credential')
               FROM validation_credentials
               WHERE validation_point_id = $1
               """,
               [fixture.ids.validation_point]
             )
  end

  test "reusing an idempotency key with different material cannot replace the winner", %{
    conn: conn
  } do
    {current_secret, _current_digest} = validation_material()
    fixture = RedemptionsFixtures.create!(validation_credential_secret: current_secret)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    {winner_secret, winner_digest} = validation_material()
    {_discarded_secret, discarded_digest} = validation_material()
    expires_at = fixture.now |> DateTime.add(90, :day) |> DateTime.to_iso8601()
    idempotency_key = "validation-credential-reused-idempotency-key"

    assert %{"data" => %{"credential" => %{"version" => 2}}} =
             rotate(
               conn,
               fixture,
               admin_token,
               idempotency_key,
               winner_digest,
               expires_at
             )

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", idempotency_key)
           |> post(rotation_path(fixture), %{
             "credential" => %{
               "secret_sha256" => discarded_digest,
               "expires_at" => expires_at
             }
           })
           |> json_response(409) == %{
             "errors" => %{"code" => "idempotency_conflict", "detail" => "Conflict"}
           }

    assert %{rows: [[2, 1]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT max(version), count(*) FILTER (WHERE status = 'active')
               FROM validation_credentials
               WHERE validation_point_id = $1
               """,
               [fixture.ids.validation_point]
             )

    grant = issue_grant!(conn, fixture)

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Validation #{winner_secret}")
           |> put_req_header("idempotency-key", "idempotency-winner-redemption")
           |> post("/api/v1/polos/#{fixture.polo_slug}/redemptions", %{"grant" => grant})
           |> json_response(201)
  end

  defp rotation_path(fixture) do
    "/api/v1/polos/#{fixture.polo_slug}/backoffice/validation-credentials/" <>
      "#{fixture.ids.validation_credential}/rotations"
  end

  defp rotate(conn, fixture, admin_token, idempotency_key, secret_sha256, expires_at) do
    conn
    |> recycle()
    |> put_req_header("authorization", "Bearer #{admin_token}")
    |> put_req_header("idempotency-key", idempotency_key)
    |> post(rotation_path(fixture), %{
      "credential" => %{
        "secret_sha256" => secret_sha256,
        "expires_at" => expires_at
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

  defp maybe_put_idempotency_key(conn, nil), do: conn

  defp maybe_put_idempotency_key(conn, idempotency_key) do
    put_req_header(conn, "idempotency-key", idempotency_key)
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
