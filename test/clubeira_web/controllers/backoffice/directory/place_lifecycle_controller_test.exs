defmodule ClubeiraWeb.Backoffice.PlaceLifecycleControllerTest do
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

  @password "uma-senha-forte-para-lifecycle-de-lugares"

  test "an admin suspends one participation and removes the place from public discovery", %{
    conn: conn
  } do
    validation_secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    fixture = RedemptionsFixtures.create!(validation_credential_secret: validation_secret)
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)

    assert fixture.ids.place in public_place_ids(conn, fixture)

    assert %{
             "data" => %{
               "polo_place_id" => polo_place_id,
               "place_id" => place_id,
               "action" => "suspend",
               "previous_status" => "active",
               "status" => "suspended",
               "revision" => 2,
               "transitioned_at" => transitioned_at
             }
           } =
             transition(
               conn,
               fixture,
               admin_token,
               "place-participation-suspension-001",
               "suspend",
               "Interrupção operacional preventiva"
             )

    assert polo_place_id == fixture.ids.polo_place
    assert place_id == fixture.ids.place
    assert {:ok, _transitioned_at, 0} = DateTime.from_iso8601(transitioned_at)
    refute fixture.ids.place in public_place_ids(conn, fixture)

    assert %{
             "data" => [
               %{
                 "id" => validation_point_id,
                 "status" => "active",
                 "revision" => 1,
                 "credential" => %{"status" => "active"}
               }
             ]
           } =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(
               "/api/v1/polos/#{fixture.polo_slug}/backoffice/validation-points" <>
                 "?place_id=#{fixture.ids.place}"
             )
             |> json_response(200)

    assert validation_point_id == fixture.ids.validation_point
  end

  test "an admin reactivates a current participation and its inventory revision", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)

    assert %{"data" => %{"status" => "suspended", "revision" => 2}} =
             transition(
               conn,
               fixture,
               admin_token,
               "place-participation-before-reactivation",
               "suspend",
               "Pausa para conferência operacional"
             )

    assert %{
             "data" => %{
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
               "place-participation-reactivation-001",
               "reactivate",
               "Operação conferida e liberada"
             )

    assert fixture.ids.place in public_place_ids(conn, fixture)

    assert %{
             "data" => [
               %{
                 "polo_place_id" => polo_place_id,
                 "status" => "active",
                 "revision" => 3
               }
             ]
           } =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(
               "/api/v1/polos/#{fixture.polo_slug}/backoffice/places" <>
                 "?place_id=#{fixture.ids.place}"
             )
             |> json_response(200)

    assert polo_place_id == fixture.ids.polo_place
  end

  test "the HTTP boundary rejects a stale expected revision without overwriting state", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)

    assert conn
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "place-participation-http-first-operator")
           |> post(lifecycle_path(fixture), %{
             "action" => "suspend",
             "reason" => "Primeiro operador confirmou a pausa",
             "expected_polo_place_id" => fixture.ids.polo_place,
             "expected_revision" => 1
           })
           |> json_response(200)
           |> get_in(["data", "revision"]) == 2

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "place-participation-http-stale-operator")
           |> post(lifecycle_path(fixture), %{
             "action" => "retire",
             "reason" => "Segundo operador permaneceu na tela antiga",
             "expected_polo_place_id" => fixture.ids.polo_place,
             "expected_revision" => 1
           })
           |> json_response(409) == %{
             "errors" => %{"code" => "stale_place_participation", "detail" => "Conflict"}
           }

    assert %{"data" => [%{"status" => "suspended", "revision" => 2}]} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(
               "/api/v1/polos/#{fixture.polo_slug}/backoffice/places" <>
                 "?place_id=#{fixture.ids.place}"
             )
             |> json_response(200)
  end

  test "an admin retires a participation and removes it permanently from discovery", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    key = "place-participation-retirement-001"
    reason = "Encerramento definitivo da parceria"

    assert fixture.ids.place in public_place_ids(conn, fixture)

    first = transition(conn, fixture, admin_token, key, "retire", reason, 1)

    assert %{
             "data" => %{
               "action" => "retire",
               "previous_status" => "active",
               "status" => "retired",
               "revision" => 2
             }
           } = first

    assert transition(conn, fixture, admin_token, key, "retire", reason, 1) == first

    refute fixture.ids.place in public_place_ids(conn, fixture)

    assert %{
             "data" => [
               %{
                 "polo_place_id" => polo_place_id,
                 "status" => "retired",
                 "revision" => 2,
                 "participation" => %{"ends_at" => ends_at}
               }
             ]
           } =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(
               "/api/v1/polos/#{fixture.polo_slug}/backoffice/places" <>
                 "?place_id=#{fixture.ids.place}"
             )
             |> json_response(200)

    assert polo_place_id == fixture.ids.polo_place
    assert {:ok, _ends_at, 0} = DateTime.from_iso8601(ends_at)

    assert {:ok, :verified} =
             Repo.transact_in_polo(admin_scope, fn repo ->
               event =
                 repo.one!(
                   from(event in DomainEvent,
                     where:
                       event.aggregate_type == "polo_place" and
                         event.aggregate_id == ^fixture.ids.polo_place and
                         event.event_type == "polo_place.retired"
                   )
                 )

               audit =
                 repo.one!(
                   from(audit in TenantEvent,
                     where:
                       audit.resource_id == ^fixture.ids.polo_place and
                         audit.action == "polo_place.retired"
                   )
                 )

               outbox = repo.get_by!(OutboxMessage, domain_event_id: event.id)

               assert event.aggregate_version == 2
               assert audit.metadata["reason"] == reason
               assert outbox.topic == "directory.polo_places.retired"
               refute inspect([first, event.payload, outbox.payload]) =~ reason

               {:ok, :verified}
             end)

    assert transition_conflict(
             conn,
             fixture,
             admin_token,
             "place-participation-reactivation-after-retirement",
             "reactivate",
             "Tentativa de reabrir parceria encerrada"
           ) == %{
             "errors" => %{
               "code" => "invalid_place_participation_transition",
               "detail" => "Conflict"
             }
           }
  end

  test "a suspended participation can be retired but never reactivated", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)

    assert %{"data" => %{"status" => "suspended", "revision" => 2}} =
             transition(
               conn,
               fixture,
               admin_token,
               "place-participation-suspend-before-retirement",
               "suspend",
               "Preparação para encerramento da parceria"
             )

    assert %{
             "data" => %{
               "action" => "retire",
               "previous_status" => "suspended",
               "status" => "retired",
               "revision" => 3
             }
           } =
             transition(
               conn,
               fixture,
               admin_token,
               "place-participation-retire-after-suspension",
               "retire",
               "Encerramento confirmado após suspensão"
             )

    assert transition_conflict(
             conn,
             fixture,
             admin_token,
             "place-participation-reactivate-after-suspended-retirement",
             "reactivate",
             "Tentativa de reativação terminal"
           ) == %{
             "errors" => %{
               "code" => "invalid_place_participation_transition",
               "detail" => "Conflict"
             }
           }
  end

  test "an exact retry keeps one observable transition and its reason private", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    key = "place-participation-observable-suspension"
    reason = "Incidente operacional confidencial no parceiro"

    first = transition(conn, fixture, admin_token, key, "suspend", reason, 1)
    replayed = transition(conn, fixture, admin_token, key, "suspend", reason, 1)

    assert replayed == first

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", key)
           |> post(lifecycle_path(fixture), %{
             "action" => "suspend",
             "reason" => "Conteúdo diferente para a mesma chave",
             "expected_polo_place_id" => fixture.ids.polo_place,
             "expected_revision" => 1
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
                       event.aggregate_type == "polo_place" and
                         event.aggregate_id == ^fixture.ids.polo_place and
                         event.event_type == "polo_place.suspended"
                   )
                 )

               audit =
                 repo.one!(
                   from(audit in TenantEvent,
                     where:
                       audit.resource_id == ^fixture.ids.polo_place and
                         audit.action == "polo_place.suspended"
                   )
                 )

               outbox = repo.get_by!(OutboxMessage, domain_event_id: event.id)

               idempotency =
                 repo.one!(
                   from(idempotency in Key,
                     where:
                       idempotency.scope == "directory.transition_place_participation" and
                         idempotency.idempotency_key == ^key
                   )
                 )

               assert event.aggregate_version == 2
               assert outbox.topic == "directory.polo_places.suspended"
               assert outbox.message_key == fixture.ids.polo_place
               assert audit.metadata["reason"] == reason
               assert idempotency.resource_id == fixture.ids.polo_place
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

  test "reactivation requires an active global place and replays one stable conflict", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!(place_status: "temporarily_closed")
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)

    assert %{"data" => %{"status" => "suspended", "revision" => 2}} =
             transition(
               conn,
               fixture,
               admin_token,
               "place-participation-suspend-before-unavailable-reactivation",
               "suspend",
               "Pausa enquanto a identidade global está indisponível"
             )

    expected_error = %{
      "errors" => %{"code" => "place_unavailable", "detail" => "Conflict"}
    }

    for _attempt <- 1..2 do
      assert transition_conflict(
               conn,
               fixture,
               admin_token,
               "place-participation-unavailable-reactivation",
               "reactivate",
               "Tentativa de retorno com identidade global inativa"
             ) == expected_error
    end

    assert %{rows: [["suspended", 2, 1, 1]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 participation.status,
                 participation.revision,
                 (SELECT count(*)
                    FROM tenant_idempotency_keys
                   WHERE scope = 'directory.transition_place_participation'
                     AND idempotency_key = 'place-participation-unavailable-reactivation'
                     AND status = 'failed'
                     AND response_status = 409),
                 (SELECT count(*)
                    FROM tenant_audit_events
                   WHERE resource_id = participation.id
                     AND action = 'polo_place.transition_rejected'
                     AND metadata->>'reason' = 'place_unavailable')
               FROM polo_places AS participation
               WHERE participation.id = $1
               """,
               [fixture.ids.polo_place]
             )
  end

  test "an expired participation cannot be reactivated as if it were current", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)

    assert %{"data" => %{"status" => "suspended", "revision" => 2}} =
             transition(
               conn,
               fixture,
               admin_token,
               "place-participation-suspend-before-expiry",
               "suspend",
               "Pausa antes do fim da vigência"
             )

    ended_range =
      Clubeira.Factory.tstz_range(
        DateTime.add(fixture.now, -2, :hour),
        DateTime.add(fixture.now, -1, :hour)
      )

    RedemptionsFixtures.scoped_query!(
      fixture,
      "UPDATE polo_places SET participation_during = $2 WHERE id = $1",
      [fixture.ids.polo_place, ended_range]
    )

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "place-participation-expired-reactivation")
           |> post(lifecycle_path(fixture), %{
             "action" => "reactivate",
             "reason" => "Tentativa após o fim da vigência",
             "expected_polo_place_id" => fixture.ids.polo_place,
             "expected_revision" => 2
           })
           |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}

    assert %{rows: [["suspended", 2, 0]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 participation.status,
                 participation.revision,
                 (SELECT count(*)
                    FROM tenant_idempotency_keys
                   WHERE scope = 'directory.transition_place_participation'
                     AND idempotency_key = 'place-participation-expired-reactivation')
               FROM polo_places AS participation
               WHERE participation.id = $1
               """,
               [fixture.ids.polo_place]
             )
  end

  test "only an admin from the routed polo can change a participation", %{conn: conn} do
    authorized = RedemptionsFixtures.create!()
    other_polo = RedemptionsFixtures.create!()
    moderator_scope = ReviewsFixtures.grant_moderator!(authorized)
    moderator_token = authenticate!(moderator_scope.actor_user_id)
    other_admin_scope = ReviewsFixtures.grant_moderator!(other_polo, role_key: "admin")
    other_admin_token = authenticate!(other_admin_scope.actor_user_id)

    assert conn
           |> put_req_header("authorization", "Bearer #{moderator_token}")
           |> put_req_header("idempotency-key", "place-participation-moderator-suspension")
           |> post(lifecycle_path(authorized), %{
             "action" => "suspend",
             "reason" => "Tentativa sem capacidade administrativa",
             "expected_polo_place_id" => authorized.ids.polo_place,
             "expected_revision" => 1
           })
           |> json_response(403) == %{"errors" => %{"detail" => "Forbidden"}}

    cross_polo_path =
      "/api/v1/polos/#{other_polo.polo_slug}/backoffice/places/" <>
        "#{authorized.ids.place}/lifecycle-actions"

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{other_admin_token}")
           |> put_req_header("idempotency-key", "place-participation-cross-polo-suspension")
           |> post(cross_polo_path, %{
             "action" => "suspend",
             "reason" => "Tentativa sobre participação de outro polo",
             "expected_polo_place_id" => authorized.ids.polo_place,
             "expected_revision" => 1
           })
           |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}

    assert %{rows: [["active", 1, 0, 0]]} =
             RedemptionsFixtures.scoped_query!(
               authorized,
               """
               SELECT
                 participation.status,
                 participation.revision,
                 (SELECT count(*)
                    FROM tenant_idempotency_keys
                   WHERE scope = 'directory.transition_place_participation'),
                 (SELECT count(*)
                    FROM domain_events
                   WHERE aggregate_type = 'polo_place'
                     AND event_type IN ('polo_place.suspended', 'polo_place.reactivated'))
               FROM polo_places AS participation
               WHERE participation.id = $1
               """,
               [authorized.ids.polo_place]
             )
  end

  test "invalid lifecycle contracts fail before reserving idempotency", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)

    assert conn
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> post(lifecycle_path(fixture), %{
             "action" => "suspend",
             "reason" => "Header ausente",
             "expected_polo_place_id" => fixture.ids.polo_place,
             "expected_revision" => 1
           })
           |> json_response(400) == %{
             "errors" => %{
               "code" => "invalid_idempotency_key",
               "detail" => "Bad Request"
             }
           }

    for {key, body} <- [
          {"short",
           %{
             "action" => "suspend",
             "reason" => "Chave curta",
             "expected_polo_place_id" => fixture.ids.polo_place,
             "expected_revision" => 1
           }},
          {"place-participation-invalid-action",
           %{
             "action" => "delete",
             "reason" => "Ação destrutiva inexistente",
             "expected_polo_place_id" => fixture.ids.polo_place,
             "expected_revision" => 1
           }},
          {"place-participation-invalid-reason",
           %{
             "action" => "suspend",
             "reason" => "x",
             "expected_polo_place_id" => fixture.ids.polo_place,
             "expected_revision" => 1
           }},
          {"place-participation-missing-aggregate",
           %{
             "action" => "suspend",
             "reason" => "Identidade da participação ausente",
             "expected_revision" => 1
           }},
          {"place-participation-invalid-aggregate",
           %{
             "action" => "suspend",
             "reason" => "Identidade da participação inválida",
             "expected_polo_place_id" => "not-a-uuid",
             "expected_revision" => 1
           }},
          {"place-participation-missing-revision",
           %{
             "action" => "suspend",
             "reason" => "Revisão esperada ausente",
             "expected_polo_place_id" => fixture.ids.polo_place
           }},
          {"place-participation-zero-revision",
           %{
             "action" => "suspend",
             "reason" => "Revisão zero não existe",
             "expected_polo_place_id" => fixture.ids.polo_place,
             "expected_revision" => 0
           }},
          {"place-participation-negative-revision",
           %{
             "action" => "suspend",
             "reason" => "Revisão negativa não existe",
             "expected_polo_place_id" => fixture.ids.polo_place,
             "expected_revision" => -1
           }},
          {"place-participation-text-revision",
           %{
             "action" => "suspend",
             "reason" => "Revisão textual não existe",
             "expected_polo_place_id" => fixture.ids.polo_place,
             "expected_revision" => "first"
           }},
          {"place-participation-unknown-field",
           %{
             "action" => "suspend",
             "reason" => "Campo fora do contrato publicado",
             "expected_polo_place_id" => fixture.ids.polo_place,
             "expected_revision" => 1,
             "unexpected" => true
           }}
        ] do
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> put_req_header("idempotency-key", key)
             |> post(lifecycle_path(fixture), body)
             |> json_response(422) == %{
               "errors" => %{"detail" => "Unprocessable Content"}
             }
    end

    invalid_id_path =
      "/api/v1/polos/#{fixture.polo_slug}/backoffice/places/not-a-uuid/lifecycle-actions"

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "place-participation-invalid-id")
           |> post(invalid_id_path, %{
             "action" => "suspend",
             "reason" => "Identidade inválida",
             "expected_polo_place_id" => fixture.ids.polo_place,
             "expected_revision" => 1
           })
           |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}

    assert %{rows: [["active", 1, 0]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 participation.status,
                 participation.revision,
                 (SELECT count(*)
                    FROM tenant_idempotency_keys
                   WHERE scope = 'directory.transition_place_participation')
               FROM polo_places AS participation
               WHERE participation.id = $1
               """,
               [fixture.ids.polo_place]
             )
  end

  test "an invalid state transition is audited once and replays stably", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)

    assert %{"data" => %{"status" => "suspended", "revision" => 2}} =
             transition(
               conn,
               fixture,
               admin_token,
               "place-participation-valid-suspension",
               "suspend",
               "Primeira suspensão operacional"
             )

    expected_error = %{
      "errors" => %{
        "code" => "invalid_place_participation_transition",
        "detail" => "Conflict"
      }
    }

    for _attempt <- 1..2 do
      assert transition_conflict(
               conn,
               fixture,
               admin_token,
               "place-participation-duplicate-suspension",
               "suspend",
               "Suspensão repetida por engano"
             ) == expected_error
    end

    assert %{rows: [["suspended", 2, 1, 1, 1]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 participation.status,
                 participation.revision,
                 (SELECT count(*)
                    FROM tenant_idempotency_keys
                   WHERE scope = 'directory.transition_place_participation'
                     AND idempotency_key = 'place-participation-duplicate-suspension'
                     AND status = 'failed'
                     AND response_status = 409),
                 (SELECT count(*)
                    FROM tenant_audit_events
                   WHERE resource_id = participation.id
                     AND action = 'polo_place.transition_rejected'
                     AND metadata->>'reason' = 'invalid_place_participation_transition'),
                 (SELECT count(*)
                    FROM domain_events
                   WHERE aggregate_type = 'polo_place'
                     AND aggregate_id = participation.id
                     AND event_type = 'polo_place.suspended')
               FROM polo_places AS participation
               WHERE participation.id = $1
               """,
               [fixture.ids.polo_place]
             )
  end

  defp lifecycle_path(fixture) do
    "/api/v1/polos/#{fixture.polo_slug}/backoffice/places/" <>
      "#{fixture.ids.place}/lifecycle-actions"
  end

  defp public_place_ids(conn, fixture) do
    response =
      conn
      |> recycle()
      |> get("/api/v1/polos/#{fixture.polo_slug}/places")
      |> json_response(200)

    Enum.map(response["data"]["places"], & &1["place_id"])
  end

  defp transition(
         conn,
         fixture,
         admin_token,
         idempotency_key,
         action,
         reason,
         expected_revision \\ nil
       ) do
    conn
    |> recycle()
    |> put_req_header("authorization", "Bearer #{admin_token}")
    |> put_req_header("idempotency-key", idempotency_key)
    |> post(lifecycle_path(fixture), %{
      "action" => action,
      "reason" => reason,
      "expected_polo_place_id" => fixture.ids.polo_place,
      "expected_revision" => expected_revision || current_revision(fixture)
    })
    |> json_response(200)
  end

  defp transition_conflict(
         conn,
         fixture,
         admin_token,
         idempotency_key,
         action,
         reason,
         expected_revision \\ nil
       ) do
    conn
    |> recycle()
    |> put_req_header("authorization", "Bearer #{admin_token}")
    |> put_req_header("idempotency-key", idempotency_key)
    |> post(lifecycle_path(fixture), %{
      "action" => action,
      "reason" => reason,
      "expected_polo_place_id" => fixture.ids.polo_place,
      "expected_revision" => expected_revision || current_revision(fixture)
    })
    |> json_response(409)
  end

  defp current_revision(fixture) do
    %{rows: [[revision]]} =
      RedemptionsFixtures.scoped_query!(
        fixture,
        "SELECT revision FROM polo_places WHERE id = $1",
        [fixture.ids.polo_place]
      )

    revision
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session.token
  end
end
