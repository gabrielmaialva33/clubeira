defmodule Clubeira.Operations.ConcurrencyTest do
  use ExUnit.Case, async: false

  alias Clubeira.Events
  alias Clubeira.Events.OutboxMessage
  alias Clubeira.Operations
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  setup_all do
    suffix = Ecto.UUID.generate() |> String.replace("-", "")
    database = "clubeira_operations_concurrency_#{suffix}"
    restricted_role = "clubeira_operations_runtime_#{suffix}"

    with_admin_connection(fn admin ->
      Postgrex.query!(admin, ~s|CREATE DATABASE "#{database}" TEMPLATE template0|, [])
    end)

    on_exit(fn ->
      with_admin_connection(fn admin ->
        Postgrex.query!(admin, ~s|DROP DATABASE "#{database}" WITH (FORCE)|, [])
      end)
    end)

    repo =
      Repo.config()
      |> Keyword.put(:database, database)
      |> Keyword.put(:name, nil)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 4)
      |> then(&start_supervised!({Repo, &1}))

    Ecto.Migrator.run(
      Repo,
      Ecto.Migrator.migrations_path(Repo),
      :up,
      all: true,
      dynamic_repo: repo,
      log: false
    )

    Repo.put_dynamic_repo(repo)
    Repo.query!("CREATE ROLE #{restricted_role} NOLOGIN NOSUPERUSER NOBYPASSRLS")
    Repo.query!("GRANT USAGE ON SCHEMA public TO #{restricted_role}")

    Repo.query!(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO #{restricted_role}"
    )

    {:ok, repo: repo, restricted_role: restricted_role}
  end

  setup %{repo: repo} do
    Repo.put_dynamic_repo(repo)
    :ok
  end

  test "concurrent retries converge on one requeue, audit fact, and idempotency record", %{
    repo: repo,
    restricted_role: restricted_role
  } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    message_id = emit_dead_letter!(fixture)
    request = %{"idempotency_key" => "outbox-concurrent-retry-1"}

    results =
      run_concurrently(repo, restricted_role, [
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

  defp run_concurrently(repo, restricted_role, operations) do
    caller = self()

    tasks =
      Enum.map(operations, fn operation ->
        Task.async(fn -> run_concurrent_operation(repo, restricted_role, operation, caller) end)
      end)

    ready_processes =
      Enum.map(tasks, fn _task ->
        receive do
          {:ready, process} -> process
        after
          5_000 -> flunk("concurrent outbox retry worker did not become ready")
        end
      end)

    Enum.each(ready_processes, &send(&1, :run))
    Task.await_many(tasks, 15_000)
  end

  defp run_concurrent_operation(repo, restricted_role, operation, caller) do
    Repo.put_dynamic_repo(repo)
    send(caller, {:ready, self()})

    receive do
      :run -> Repo.checkout(fn -> run_as_role(restricted_role, operation) end)
    end
  end

  defp run_as_role(restricted_role, operation) do
    Repo.query!("SET ROLE #{restricted_role}")

    try do
      operation.()
    after
      Repo.query!("RESET ROLE")
    end
  end

  defp connection_options(database) do
    Repo.config()
    |> Keyword.take([:hostname, :port, :username, :password, :ssl, :socket_options])
    |> Keyword.put(:database, database)
  end

  defp with_admin_connection(operation) do
    {:ok, admin} = Postgrex.start_link(connection_options("postgres"))

    try do
      operation.(admin)
    after
      GenServer.stop(admin)
    end
  end
end
