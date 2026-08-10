defmodule ClubeiraWeb.Backoffice.OperationsControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.Audit
  alias Clubeira.Events
  alias Clubeira.Events.OutboxMessage
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  @password "uma-senha-forte-para-operacoes-backoffice"

  test "a polo admin lists its dead letters without delivery internals or event payloads", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    other_polo = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)

    %{aggregate_id: aggregate_id, message_id: message_id} =
      emit_dead_letter!(fixture, "private-member-reference")

    %{message_id: other_message_id} =
      emit_dead_letter!(other_polo, "other-polo-private-reference")

    assert %{
             "data" => [
               %{
                 "id" => listed_message_id,
                 "status" => "dead_letter",
                 "topic" => "tests.operations",
                 "attempt_count" => 3,
                 "available_at" => available_at,
                 "published_at" => nil,
                 "recorded_at" => recorded_at,
                 "has_error" => true,
                 "event" => %{
                   "type" => "test.operations.failed",
                   "aggregate_type" => "test_operation",
                   "aggregate_id" => listed_aggregate_id,
                   "occurred_at" => occurred_at
                 }
               } = message
             ],
             "meta" => %{
               "count" => 1,
               "page" => %{"limit" => 20, "has_more" => false, "next_cursor" => nil}
             }
           } =
             conn
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(
               "/api/v1/polos/#{fixture.polo_slug}/backoffice/outbox-messages?status=dead_letter"
             )
             |> json_response(200)

    assert listed_message_id == message_id
    assert listed_aggregate_id == aggregate_id
    refute listed_message_id == other_message_id

    for timestamp <- [available_at, recorded_at, occurred_at] do
      assert {:ok, _datetime, 0} = DateTime.from_iso8601(timestamp)
    end

    for private_field <- ~w(payload last_error locked_by message_key metadata) do
      refute Map.has_key?(message, private_field)
      refute get_in(message, ["event", private_field])
    end

    encoded_response = Jason.encode!(message)
    refute encoded_response =~ "private-member-reference"
    refute encoded_response =~ "postgres-password-leaked-by-driver"
  end

  test "the outbox feed filters by topic and paginates with an opaque stable cursor", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)

    %{message_id: older_message_id} =
      emit_dead_letter!(fixture, "older", %{topic: "operations.retry"})

    %{message_id: newer_message_id} =
      emit_dead_letter!(fixture, "newer", %{topic: "operations.retry"})

    %{message_id: ignored_message_id} =
      emit_dead_letter!(fixture, "ignored", %{topic: "operations.other"})

    path = "/api/v1/polos/#{fixture.polo_slug}/backoffice/outbox-messages"

    query =
      URI.encode_query(%{"limit" => 1, "status" => "dead_letter", "topic" => "operations.retry"})

    assert %{
             "data" => [%{"id" => first_message_id, "topic" => "operations.retry"}],
             "meta" => %{
               "count" => 1,
               "page" => %{"limit" => 1, "has_more" => true, "next_cursor" => cursor}
             }
           } =
             conn
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(path <> "?#{query}")
             |> json_response(200)

    assert first_message_id == newer_message_id
    assert is_binary(cursor)
    refute cursor =~ newer_message_id

    next_query =
      URI.encode_query(%{
        "after" => cursor,
        "limit" => 1,
        "status" => "dead_letter",
        "topic" => "operations.retry"
      })

    assert %{
             "data" => [%{"id" => second_message_id, "topic" => "operations.retry"}],
             "meta" => %{
               "count" => 1,
               "page" => %{"limit" => 1, "has_more" => false, "next_cursor" => nil}
             }
           } =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(path <> "?#{next_query}")
             |> json_response(200)

    assert second_message_id == older_message_id
    refute second_message_id == ignored_message_id
  end

  test "a polo admin reads its audit timeline without private metadata", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    other_polo = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    resource_id = Ecto.UUID.generate(version: 7)

    audit_id = record_audit!(fixture, resource_id, "private operational explanation")
    other_audit_id = record_audit!(other_polo, Ecto.UUID.generate(version: 7), "other polo")

    query =
      URI.encode_query(%{
        "action" => "test.operation.completed",
        "resource_type" => "test_operation"
      })

    assert %{
             "data" => [
               %{
                 "id" => listed_audit_id,
                 "actor_user_id" => actor_user_id,
                 "actor_kind" => "user",
                 "action" => "test.operation.completed",
                 "resource_type" => "test_operation",
                 "resource_id" => listed_resource_id,
                 "request_id" => request_id,
                 "correlation_id" => correlation_id,
                 "occurred_at" => occurred_at,
                 "recorded_at" => recorded_at
               } = audit_event
             ],
             "meta" => %{
               "count" => 1,
               "page" => %{"limit" => 20, "has_more" => false, "next_cursor" => nil}
             }
           } =
             conn
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get("/api/v1/polos/#{fixture.polo_slug}/backoffice/audit-events?#{query}")
             |> json_response(200)

    assert listed_audit_id == audit_id
    assert listed_resource_id == resource_id
    assert actor_user_id == fixture.scope.actor_user_id
    assert request_id == fixture.scope.request_id
    assert correlation_id == fixture.scope.request_id
    refute listed_audit_id == other_audit_id

    for timestamp <- [occurred_at, recorded_at] do
      assert {:ok, _datetime, 0} = DateTime.from_iso8601(timestamp)
    end

    refute Map.has_key?(audit_event, "metadata")
    refute Map.has_key?(audit_event, "client_ip")
    refute Jason.encode!(audit_event) =~ "private operational explanation"
  end

  test "the audit timeline paginates append-only facts with an opaque stable cursor", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    older_audit_id = record_audit!(fixture, Ecto.UUID.generate(version: 7), "older")
    newer_audit_id = record_audit!(fixture, Ecto.UUID.generate(version: 7), "newer")
    path = "/api/v1/polos/#{fixture.polo_slug}/backoffice/audit-events"
    query = URI.encode_query(%{"action" => "test.operation.completed", "limit" => 1})

    assert %{
             "data" => [%{"id" => first_audit_id}],
             "meta" => %{
               "count" => 1,
               "page" => %{"limit" => 1, "has_more" => true, "next_cursor" => cursor}
             }
           } =
             conn
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(path <> "?#{query}")
             |> json_response(200)

    assert first_audit_id == newer_audit_id
    assert is_binary(cursor)
    refute cursor =~ newer_audit_id

    next_query =
      URI.encode_query(%{
        "action" => "test.operation.completed",
        "after" => cursor,
        "limit" => 1
      })

    assert %{
             "data" => [%{"id" => second_audit_id}],
             "meta" => %{
               "count" => 1,
               "page" => %{"limit" => 1, "has_more" => false, "next_cursor" => nil}
             }
           } =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(path <> "?#{next_query}")
             |> json_response(200)

    assert second_audit_id == older_audit_id
  end

  test "a polo admin requeues a dead letter exactly once and sees the audit fact", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    %{message_id: message_id} = emit_dead_letter!(fixture, "retry-private-reference")

    retry_path =
      "/api/v1/polos/#{fixture.polo_slug}/backoffice/outbox-messages/#{message_id}/retries"

    first_response =
      conn
      |> put_req_header("authorization", "Bearer #{admin_token}")
      |> put_req_header("idempotency-key", "retry-dead-letter-1")
      |> post(retry_path, %{})
      |> json_response(200)

    assert %{
             "data" => %{
               "id" => listed_message_id,
               "status" => "pending",
               "attempt_count" => 0,
               "available_at" => available_at,
               "requeued_at" => requeued_at
             }
           } = first_response

    assert listed_message_id == message_id
    assert available_at == requeued_at
    assert {:ok, _datetime, 0} = DateTime.from_iso8601(requeued_at)

    assert first_response ==
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> put_req_header("idempotency-key", "retry-dead-letter-1")
             |> post(retry_path, %{})
             |> json_response(200)

    outbox_query = URI.encode_query(%{"status" => "pending", "topic" => "tests.operations"})

    assert %{
             "data" => [
               %{
                 "id" => ^message_id,
                 "status" => "pending",
                 "attempt_count" => 0,
                 "has_error" => false
               }
             ]
           } =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(
               "/api/v1/polos/#{fixture.polo_slug}/backoffice/outbox-messages?#{outbox_query}"
             )
             |> json_response(200)

    audit_query =
      URI.encode_query(%{
        "action" => "outbox.message_requeued",
        "resource_type" => "outbox_message"
      })

    assert %{
             "data" => [
               %{
                 "actor_user_id" => actor_user_id,
                 "action" => "outbox.message_requeued",
                 "resource_type" => "outbox_message",
                 "resource_id" => ^message_id
               }
             ],
             "meta" => %{"count" => 1}
           } =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get("/api/v1/polos/#{fixture.polo_slug}/backoffice/audit-events?#{audit_query}")
             |> json_response(200)

    assert actor_user_id == admin_scope.actor_user_id
  end

  test "operations feeds require a polo admin and reject malformed filters", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    member_token = authenticate!(fixture.ids.user)
    base_path = "/api/v1/polos/#{fixture.polo_slug}/backoffice"

    for path <- ["#{base_path}/audit-events", "#{base_path}/outbox-messages"] do
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{member_token}")
             |> get(path)
             |> json_response(403) == %{"errors" => %{"detail" => "Forbidden"}}
    end

    for path <- [
          "#{base_path}/outbox-messages?limit=0",
          "#{base_path}/outbox-messages?limit=101",
          "#{base_path}/outbox-messages?after=not-a-cursor",
          "#{base_path}/audit-events?limit=0",
          "#{base_path}/audit-events?after=not-a-cursor"
        ] do
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(path)
             |> json_response(400) == %{"errors" => %{"detail" => "Bad Request"}}
    end

    for path <- [
          "#{base_path}/outbox-messages?status=unknown",
          "#{base_path}/outbox-messages?topic=%20%20",
          "#{base_path}/audit-events?action=%20%20",
          "#{base_path}/audit-events?resource_type=%20%20"
        ] do
      assert conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> get(path)
             |> json_response(422) == %{
               "errors" => %{"detail" => "Unprocessable Content"}
             }
    end
  end

  test "outbox retry fails closed for invalid authority, state, tenant, and idempotency", %{
    conn: conn
  } do
    fixture = RedemptionsFixtures.create!()
    other_polo = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    member_token = authenticate!(fixture.ids.user)
    %{message_id: message_id} = emit_dead_letter!(fixture, "guarded-retry")
    %{message_id: other_message_id} = emit_dead_letter!(other_polo, "other-polo-retry")

    path =
      "/api/v1/polos/#{fixture.polo_slug}/backoffice/outbox-messages/#{message_id}/retries"

    assert conn
           |> put_req_header("authorization", "Bearer #{member_token}")
           |> put_req_header("idempotency-key", "retry-forbidden-1")
           |> post(path, %{})
           |> json_response(403) == %{"errors" => %{"detail" => "Forbidden"}}

    for key <- [nil, "short", "invalid key with spaces"] do
      request =
        conn
        |> recycle()
        |> put_req_header("authorization", "Bearer #{admin_token}")
        |> maybe_put_idempotency_key(key)
        |> post(path, %{})

      assert json_response(request, 400) == %{
               "errors" => %{
                 "code" => "invalid_idempotency_key",
                 "detail" => "Bad Request"
               }
             }
    end

    other_path =
      "/api/v1/polos/#{fixture.polo_slug}/backoffice/outbox-messages/#{other_message_id}/retries"

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "retry-other-tenant-1")
           |> post(other_path, %{})
           |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}

    assert %{"data" => %{"status" => "pending"}} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> put_req_header("idempotency-key", "retry-state-1")
             |> post(path, %{})
             |> json_response(200)

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "retry-state-2")
           |> post(path, %{})
           |> json_response(409) == %{
             "errors" => %{
               "code" => "outbox_message_not_retryable",
               "detail" => "Conflict"
             }
           }
  end

  test "one idempotency key cannot requeue two different messages", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    admin_token = authenticate!(admin_scope.actor_user_id)
    %{message_id: first_message_id} = emit_dead_letter!(fixture, "first-idempotency")
    %{message_id: second_message_id} = emit_dead_letter!(fixture, "second-idempotency")
    base_path = "/api/v1/polos/#{fixture.polo_slug}/backoffice/outbox-messages"

    assert %{"data" => %{"id" => ^first_message_id, "status" => "pending"}} =
             conn
             |> put_req_header("authorization", "Bearer #{admin_token}")
             |> put_req_header("idempotency-key", "retry-shared-key-1")
             |> post("#{base_path}/#{first_message_id}/retries", %{})
             |> json_response(200)

    assert conn
           |> recycle()
           |> put_req_header("authorization", "Bearer #{admin_token}")
           |> put_req_header("idempotency-key", "retry-shared-key-1")
           |> post("#{base_path}/#{second_message_id}/retries", %{})
           |> json_response(409) == %{
             "errors" => %{"code" => "idempotency_conflict", "detail" => "Conflict"}
           }
  end

  defp emit_dead_letter!(fixture, private_reference, overrides \\ %{}) do
    aggregate_id = Ecto.UUID.generate(version: 7)
    topic = Map.get(overrides, :topic, "tests.operations")

    {:ok, message_id} =
      Repo.transact_in_polo(fixture.scope, fn repo ->
        now = DateTime.utc_now(:microsecond)

        event =
          Events.emit!(repo, %{
            polo_id: fixture.ids.polo,
            aggregate_type: "test_operation",
            aggregate_id: aggregate_id,
            aggregate_version: 1,
            event_type: "test.operations.failed",
            topic: topic,
            message_key: private_reference,
            payload: %{"private_reference" => private_reference},
            metadata: %{"private_reference" => private_reference},
            occurred_at: now
          })

        message = Repo.get_by!(OutboxMessage, domain_event_id: event.id)
        {:ok, message.id}
      end)

    RedemptionsFixtures.scoped_query!(
      fixture,
      """
      UPDATE outbox_messages
      SET status = 'dead_letter',
          attempt_count = 3,
          locked_at = NULL,
          locked_by = NULL,
          last_error = 'postgres-password-leaked-by-driver'
      WHERE id = $1
      """,
      [message_id]
    )

    %{aggregate_id: aggregate_id, message_id: message_id}
  end

  defp record_audit!(fixture, resource_id, private_explanation) do
    {:ok, audit_id} =
      Repo.transact_in_polo(fixture.scope, fn repo ->
        now = DateTime.utc_now(:microsecond)

        audit_event =
          Audit.record_tenant!(repo, fixture.scope, %{
            action: "test.operation.completed",
            resource_type: "test_operation",
            resource_id: resource_id,
            metadata: %{"private_explanation" => private_explanation},
            occurred_at: now
          })

        {:ok, audit_event.id}
      end)

    audit_id
  end

  defp authenticate!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session.token
  end

  defp maybe_put_idempotency_key(conn, nil), do: conn

  defp maybe_put_idempotency_key(conn, key),
    do: put_req_header(conn, "idempotency-key", key)
end
