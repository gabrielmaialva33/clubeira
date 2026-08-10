defmodule Clubeira.Operations.ConcurrencyTest do
  use Clubeira.ConcurrencyCase, async: false

  alias Clubeira.Events
  alias Clubeira.Events.OutboxMessage
  alias Clubeira.Operations
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  test "concurrent retries converge on one requeue, audit fact, and idempotency record", %{
    repo: repo
  } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    message_id = emit_dead_letter!(fixture)
    request = %{"idempotency_key" => "outbox-concurrent-retry-1"}

    results =
      run_concurrently(repo, [
        fn -> Operations.retry_outbox_message(admin_scope, message_id, request) end,
        fn -> Operations.retry_outbox_message(admin_scope, message_id, request) end
      ])

    assert [{:ok, first}, {:ok, second}] = results
    assert first == second

    assert %{rows: [["pending", 0, nil, 1, 1, 1, 1]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 message.status,
                 message.attempt_count,
                 message.last_error,
                 (SELECT count(*)
                    FROM tenant_audit_events
                   WHERE polo_id = $2
                     AND action = 'outbox.message_requeued'
                     AND resource_id = $1),
                 (SELECT count(*)
                    FROM tenant_idempotency_keys
                   WHERE polo_id = $2
                     AND scope = 'operations.retry_outbox_message'
                     AND resource_id = $1),
                 (SELECT count(*) FROM domain_events WHERE polo_id = $2),
                 (SELECT count(*)
                    FROM outbox_messages AS tenant_message
                    JOIN domain_events AS tenant_event
                      ON tenant_event.id = tenant_message.domain_event_id
                   WHERE tenant_event.polo_id = $2)
               FROM outbox_messages AS message
               WHERE message.id = $1
               """,
               [message_id, fixture.ids.polo]
             )
  end

  defp emit_dead_letter!(fixture) do
    {:ok, message_id} =
      Repo.transact_in_polo(fixture.scope, fn repo ->
        now = DateTime.utc_now(:microsecond)

        event =
          Events.emit!(repo, %{
            polo_id: fixture.ids.polo,
            aggregate_type: "test_operation",
            aggregate_id: Ecto.UUID.generate(version: 7),
            aggregate_version: 1,
            event_type: "test.operations.failed",
            topic: "tests.operations",
            message_key: "concurrent-retry",
            payload: %{"test" => true},
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
          last_error = 'http_status:503'
      WHERE id = $1
      """,
      [message_id]
    )

    message_id
  end
end
