defmodule ClubeiraWeb.Backoffice.ValidationPointControllerTest do
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

  test "a polo admin provisions a validation point that can confirm a redemption", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    {validation_secret, secret_sha256} = validation_material()
    expires_at = fixture.now |> DateTime.add(90, :day) |> DateTime.to_iso8601()

    provisioned =
      conn
      |> put_req_header("authorization", "Bearer #{admin_token}")
      |> put_req_header("idempotency-key", "validation-point-provision-001")
      |> post(
        "/api/v1/polos/#{fixture.polo_slug}/backoffice/places/#{fixture.ids.place}/validation-points",
        %{
          "name" => "Caixa do balcão",
          "credential" => %{
            "secret_sha256" => secret_sha256,
            "expires_at" => expires_at
          }
        }
      )
      |> json_response(201)

    assert %{
             "data" => %{
               "id" => validation_point_id,
               "place_id" => place_id,
               "polo_place_id" => polo_place_id,
               "name" => "Caixa do balcão",
               "kind" => "api",
               "status" => "active",
               "credential" => %{
                 "id" => credential_id,
                 "version" => 1,
                 "kind" => "api_key",
                 "status" => "active",
                 "valid_from" => valid_from,
                 "expires_at" => ^expires_at
               }
             }
           } = provisioned

    assert place_id == fixture.ids.place
    assert polo_place_id == fixture.ids.polo_place
    assert {:ok, ^validation_point_id} = Ecto.UUID.cast(validation_point_id)
    assert {:ok, ^credential_id} = Ecto.UUID.cast(credential_id)
    assert {:ok, _valid_from, 0} = DateTime.from_iso8601(valid_from)
    refute inspect(provisioned) =~ validation_secret
    refute inspect(provisioned) =~ secret_sha256

    assert %{
             "data" => validation_points,
             "meta" => %{
               "count" => 2,
               "page" => %{"limit" => 20, "has_more" => false, "next_cursor" => nil}
             }
           } =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(backoffice_validation_points_path(fixture))
             |> json_response(200)

    assert %{
             "id" => ^validation_point_id,
             "polo_place_id" => ^polo_place_id,
             "name" => "Caixa do balcão",
             "kind" => "api",
             "status" => "active",
             "revision" => 1,
             "place" => %{
               "id" => ^place_id,
               "name" => place_name,
               "slug" => place_slug
             },
             "credential" => %{
               "id" => ^credential_id,
               "version" => 1,
               "kind" => "api_key",
               "status" => "active",
               "valid_from" => ^valid_from,
               "expires_at" => ^expires_at
             }
           } = Enum.find(validation_points, &(&1["id"] == validation_point_id))

    assert is_binary(place_name)
    assert is_binary(place_slug)
    refute inspect(validation_points) =~ validation_secret
    refute inspect(validation_points) =~ secret_sha256

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

    assert %{"data" => %{"validation_point_id" => ^validation_point_id}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Validation #{validation_secret}")
             |> put_req_header("idempotency-key", "provisioned-point-redemption-001")
             |> post("/api/v1/polos/#{fixture.polo_slug}/redemptions", %{"grant" => grant})
             |> json_response(201)

    assert is_binary(device_installation_id)
  end

  test "an exact retry replays the response without duplicating the point or credential", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    {_validation_secret, secret_sha256} = validation_material()
    expires_at = fixture.now |> DateTime.add(90, :day) |> DateTime.to_iso8601()
    path = validation_points_path(fixture)

    request = %{
      "name" => "Terminal da recepção",
      "credential" => %{
        "secret_sha256" => secret_sha256,
        "expires_at" => expires_at
      }
    }

    first = provision(conn, path, admin_token, "validation-point-replay-001", request)

    replayed =
      conn
      |> recycle()
      |> provision(path, admin_token, "validation-point-replay-001", request)

    assert replayed == first

    assert %{rows: [[1, 1]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT count(point.id), count(credential.id)
               FROM validation_points AS point
               LEFT JOIN validation_credentials AS credential
                 ON credential.validation_point_id = point.id
                AND credential.polo_id = point.polo_id
               WHERE point.name = 'Terminal da recepção'
               """
             )
  end

  test "a replay preserves the original response after the credential state changes", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    {_validation_secret, secret_sha256} = validation_material()
    path = validation_points_path(fixture)

    request = %{
      "name" => "Terminal com replay histórico",
      "credential" => %{
        "secret_sha256" => secret_sha256,
        "expires_at" => fixture.now |> DateTime.add(90, :day) |> DateTime.to_iso8601()
      }
    }

    first = provision(conn, path, admin_token, "validation-point-historical-replay", request)
    point_id = get_in(first, ["data", "id"])
    credential_id = get_in(first, ["data", "credential", "id"])

    RedemptionsFixtures.scoped_query!(
      fixture,
      "UPDATE validation_points SET status = 'suspended' WHERE id = $1",
      [point_id]
    )

    RedemptionsFixtures.scoped_query!(
      fixture,
      "UPDATE validation_credentials SET status = 'revoked' WHERE id = $1",
      [credential_id]
    )

    replayed =
      conn
      |> recycle()
      |> provision(path, admin_token, "validation-point-historical-replay", request)

    assert replayed == first
  end

  test "provisioning emits one auditable event without exposing credential material", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    {validation_secret, secret_sha256} = validation_material()

    response =
      provision(
        conn,
        validation_points_path(fixture),
        admin_token,
        "validation-point-observability-001",
        %{
          "name" => "Terminal auditável",
          "credential" => %{
            "secret_sha256" => secret_sha256,
            "expires_at" => fixture.now |> DateTime.add(90, :day) |> DateTime.to_iso8601()
          }
        }
      )

    point_id = get_in(response, ["data", "id"])
    credential_id = get_in(response, ["data", "credential", "id"])

    assert {:ok, :verified} =
             Repo.transact_in_polo(admin_scope, fn repo ->
               event =
                 repo.one!(
                   from(event in DomainEvent,
                     where:
                       event.aggregate_id == ^point_id and
                         event.event_type == "validation_point.provisioned"
                   )
                 )

               audit =
                 repo.one!(
                   from(audit in TenantEvent,
                     where:
                       audit.resource_id == ^point_id and
                         audit.action == "validation_point.provisioned"
                   )
                 )

               outbox = repo.get_by!(OutboxMessage, domain_event_id: event.id)
               credential = repo.get!(ValidationCredential, credential_id)

               key =
                 repo.one!(
                   from(key in Key,
                     where:
                       key.scope == "redemptions.provision_validation_point" and
                         key.idempotency_key == "validation-point-observability-001"
                   )
                 )

               assert event.aggregate_version == 1
               assert event.aggregate_id == audit.resource_id
               assert event.aggregate_id == key.resource_id
               assert key.response_status == 201
               assert outbox.topic == "redemptions.validation_points.provisioned"
               assert outbox.message_key == point_id
               assert credential.secret_hash == Base.url_decode64!(secret_sha256, padding: false)

               public_evidence =
                 inspect([event.payload, event.metadata, audit.metadata, outbox.payload])

               refute public_evidence =~ validation_secret
               refute public_evidence =~ secret_sha256

               {:ok, :verified}
             end)
  end

  test "a validation credential cannot be provisioned for more than one year", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    {_validation_secret, secret_sha256} = validation_material()

    assert conn
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "validation-point-too-long-001")
           |> post(validation_points_path(fixture), %{
             "name" => "Credencial sem rotação",
             "credential" => %{
               "secret_sha256" => secret_sha256,
               "expires_at" => fixture.now |> DateTime.add(366, :day) |> DateTime.to_iso8601()
             }
           })
           |> json_response(422) == %{"errors" => %{"detail" => "Unprocessable Content"}}

    assert %{rows: [[0]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               "SELECT count(*) FROM validation_points WHERE name = 'Credencial sem rotação'"
             )
  end

  test "an already expired credential cannot be provisioned", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    {_validation_secret, secret_sha256} = validation_material()

    assert conn
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "validation-point-expired-001")
           |> post(validation_points_path(fixture), %{
             "name" => "Credencial expirada",
             "credential" => %{
               "secret_sha256" => secret_sha256,
               "expires_at" => fixture.now |> DateTime.add(-1, :day) |> DateTime.to_iso8601()
             }
           })
           |> json_response(422) == %{"errors" => %{"detail" => "Unprocessable Content"}}

    assert %{rows: [[0, 0]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 (SELECT count(*) FROM validation_points WHERE name = 'Credencial expirada'),
                 (
                   SELECT count(*)
                   FROM tenant_idempotency_keys
                   WHERE idempotency_key = 'validation-point-expired-001'
                 )
               """
             )
  end

  test "malformed credential material is rejected before reserving idempotency", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)

    assert conn
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "validation-point-invalid-digest")
           |> post(validation_points_path(fixture), %{
             "name" => "Terminal inválido",
             "credential" => %{
               "secret_sha256" => "not-a-sha256-digest",
               "expires_at" => fixture.now |> DateTime.add(90, :day) |> DateTime.to_iso8601()
             }
           })
           |> json_response(422) == %{"errors" => %{"detail" => "Unprocessable Content"}}

    assert %{rows: [[0, 0]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 (SELECT count(*) FROM validation_points WHERE name = 'Terminal inválido'),
                 (
                   SELECT count(*)
                   FROM tenant_idempotency_keys
                   WHERE idempotency_key = 'validation-point-invalid-digest'
                 )
               """
             )
  end

  test "reusing an idempotency key for different point material conflicts without mutation", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    {_first_secret, first_sha256} = validation_material()
    {_second_secret, second_sha256} = validation_material()
    path = validation_points_path(fixture)
    expires_at = fixture.now |> DateTime.add(90, :day) |> DateTime.to_iso8601()

    assert %{"data" => %{"name" => "Terminal original"}} =
             provision(conn, path, admin_token, "validation-point-reused-key", %{
               "name" => "Terminal original",
               "credential" => %{
                 "secret_sha256" => first_sha256,
                 "expires_at" => expires_at
               }
             })

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "validation-point-reused-key")
           |> post(path, %{
             "name" => "Terminal diferente",
             "credential" => %{
               "secret_sha256" => second_sha256,
               "expires_at" => expires_at
             }
           })
           |> json_response(409) == %{
             "errors" => %{"code" => "idempotency_conflict", "detail" => "Conflict"}
           }

    assert %{rows: [[1, 0]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 count(*) FILTER (WHERE name = 'Terminal original'),
                 count(*) FILTER (WHERE name = 'Terminal diferente')
               FROM validation_points
               """
             )
  end

  test "a duplicate credential digest is a stable conflict without leaving an orphan point", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    {_validation_secret, secret_sha256} = validation_material()
    path = validation_points_path(fixture)
    expires_at = fixture.now |> DateTime.add(90, :day) |> DateTime.to_iso8601()

    assert %{"data" => %{"id" => original_point_id}} =
             provision(conn, path, admin_token, "validation-point-original-001", %{
               "name" => "Caixa original",
               "credential" => %{
                 "secret_sha256" => secret_sha256,
                 "expires_at" => expires_at
               }
             })

    duplicate_request = %{
      "name" => "Caixa duplicado",
      "credential" => %{
        "secret_sha256" => secret_sha256,
        "expires_at" => expires_at
      }
    }

    for _attempt <- 1..2 do
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> put_req_header("idempotency-key", "validation-point-duplicate-001")
             |> post(path, duplicate_request)
             |> json_response(409) == %{
               "errors" => %{
                 "code" => "validation_credential_conflict",
                 "detail" => "Conflict"
               }
             }
    end

    assert %{rows: [[^original_point_id, 0, 1, 409]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 (SELECT id::text FROM validation_points WHERE name = 'Caixa original'),
                 (SELECT count(*) FROM validation_points WHERE name = 'Caixa duplicado'),
                 (
                   SELECT count(*)
                   FROM tenant_audit_events
                   WHERE action = 'validation_point.provisioning_rejected'
                 ),
                 (
                   SELECT response_status
                   FROM tenant_idempotency_keys
                   WHERE idempotency_key = 'validation-point-duplicate-001'
                 )
               """
             )
  end

  test "a review moderator cannot provision validation points", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)
    moderator_token = authenticate!(moderator_scope.actor_user_id)
    {_validation_secret, secret_sha256} = validation_material()

    assert conn
           |> put_req_header("authorization", "Bearer #{moderator_token}")
           |> put_req_header("idempotency-key", "validation-point-forbidden-001")
           |> post(validation_points_path(fixture), %{
             "name" => "Terminal sem autorização",
             "credential" => %{
               "secret_sha256" => secret_sha256,
               "expires_at" => fixture.now |> DateTime.add(90, :day) |> DateTime.to_iso8601()
             }
           })
           |> json_response(403) == %{"errors" => %{"detail" => "Forbidden"}}

    assert %{rows: [[0]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               "SELECT count(*) FROM validation_points WHERE name = 'Terminal sem autorização'"
             )
  end

  test "an admin cannot provision a point for a place from another polo", %{conn: conn} do
    authorized = RedemptionsFixtures.create!()
    other_polo = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(authorized, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    {_validation_secret, secret_sha256} = validation_material()

    path =
      "/api/v1/polos/#{authorized.polo_slug}/backoffice/places/#{other_polo.ids.place}/validation-points"

    assert conn
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "validation-point-cross-polo-001")
           |> post(path, %{
             "name" => "Terminal cruzado",
             "credential" => %{
               "secret_sha256" => secret_sha256,
               "expires_at" => authorized.now |> DateTime.add(90, :day) |> DateTime.to_iso8601()
             }
           })
           |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}

    for fixture <- [authorized, other_polo] do
      assert %{rows: [[0]]} =
               RedemptionsFixtures.scoped_query!(
                 fixture,
                 "SELECT count(*) FROM validation_points WHERE name = 'Terminal cruzado'"
               )
    end
  end

  test "validation point inventory is tenant-safe, filterable, and keyset paginated", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    other_polo = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    moderator_scope = ReviewsFixtures.grant_moderator!(fixture)
    moderator_token = authenticate!(moderator_scope.actor_user_id)
    {_secret, secret_sha256} = validation_material()

    assert %{"data" => %{"id" => newest_point_id}} =
             provision(
               conn,
               validation_points_path(fixture),
               admin_token,
               "validation-point-feed-001",
               %{
                 "name" => "Caixa mais recente",
                 "credential" => %{
                   "secret_sha256" => secret_sha256,
                   "expires_at" => fixture.now |> DateTime.add(90, :day) |> DateTime.to_iso8601()
                 }
               }
             )

    path = backoffice_validation_points_path(fixture)

    assert %{
             "data" => [%{"id" => ^newest_point_id}],
             "meta" => %{
               "count" => 1,
               "page" => %{"limit" => 1, "has_more" => true, "next_cursor" => cursor}
             }
           } =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(path <> "?limit=1&status=active")
             |> json_response(200)

    assert is_binary(cursor)
    refute cursor =~ newest_point_id

    assert %{
             "data" => [%{"id" => original_point_id, "credential" => nil}],
             "meta" => %{
               "count" => 1,
               "page" => %{"limit" => 1, "has_more" => false, "next_cursor" => nil}
             }
           } =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(path <> "?limit=1&status=active&after=#{cursor}")
             |> json_response(200)

    assert original_point_id == fixture.ids.validation_point
    refute original_point_id == other_polo.ids.validation_point

    place_query = URI.encode_query(%{"place_id" => fixture.ids.place})

    assert %{"meta" => %{"count" => 2}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(path <> "?#{place_query}")
             |> json_response(200)

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{moderator_token}")
           |> get(path)
           |> json_response(403) == %{"errors" => %{"detail" => "Forbidden"}}

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> get(path <> "?after=not-a-cursor")
           |> json_response(400) == %{"errors" => %{"detail" => "Bad Request"}}

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> get(path <> "?status=unknown")
           |> json_response(422) == %{
             "errors" => %{"detail" => "Unprocessable Content"}
           }
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session.token
  end

  defp validation_material do
    secret = :crypto.strong_rand_bytes(32)

    {
      Base.url_encode64(secret, padding: false),
      secret |> then(&:crypto.hash(:sha256, &1)) |> Base.url_encode64(padding: false)
    }
  end

  defp random_token do
    Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end

  defp validation_points_path(fixture) do
    "/api/v1/polos/#{fixture.polo_slug}/backoffice/places/#{fixture.ids.place}/validation-points"
  end

  defp backoffice_validation_points_path(fixture) do
    "/api/v1/polos/#{fixture.polo_slug}/backoffice/validation-points"
  end

  defp provision(conn, path, token, idempotency_key, request) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("idempotency-key", idempotency_key)
    |> post(path, request)
    |> json_response(201)
  end
end
