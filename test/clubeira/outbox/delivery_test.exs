defmodule Clubeira.Outbox.DeliveryTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Events
  alias Clubeira.Events.OutboxMessage
  alias Clubeira.Outbox.Delivery
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo

  defmodule CaptureAdapter do
    @moduledoc false

    def publish(message, options) do
      send(Keyword.fetch!(options, :test_pid), {:published, message})
      :ok
    end
  end

  defmodule FailingAdapter do
    @moduledoc false

    def publish(message, options) do
      send(Keyword.fetch!(options, :test_pid), {:failed_publish, message.id})
      {:error, {:http_status, 503}}
    end
  end

  test "claims, publishes, and marks a tenant message exactly once" do
    fixture = RedemptionsFixtures.create!()
    message_id = emit_message!(fixture)

    assert {:ok, 1} =
             Delivery.run_once(fixture.scope,
               adapter: CaptureAdapter,
               adapter_options: [test_pid: self()],
               worker_id: "delivery-test",
               batch_size: 10
             )

    assert_receive {:published,
                    %OutboxMessage{
                      id: ^message_id,
                      topic: "tests.example",
                      message_key: "example-key",
                      payload: %{"event_type" => "test.example"}
                    }}

    assert %{rows: [["published", 1, published_at, nil, nil]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT status, attempt_count, published_at, locked_at, locked_by
               FROM outbox_messages
               WHERE id = $1
               """,
               [message_id]
             )

    assert %DateTime{} = published_at

    assert {:ok, 0} =
             Delivery.run_once(fixture.scope,
               adapter: CaptureAdapter,
               adapter_options: [test_pid: self()],
               worker_id: "delivery-test",
               batch_size: 10
             )

    refute_receive {:published, _message}
  end

  test "failed delivery backs off and reaches a bounded dead letter state" do
    fixture = RedemptionsFixtures.create!()
    message_id = emit_message!(fixture)

    options = [
      adapter: FailingAdapter,
      adapter_options: [test_pid: self()],
      worker_id: "failing-delivery-test",
      batch_size: 1,
      max_attempts: 2,
      retry_base_ms: 1_000,
      retry_max_ms: 1_000
    ]

    assert {:ok, 1} = Delivery.run_once(fixture.scope, options)
    assert_receive {:failed_publish, ^message_id}

    assert %{rows: [["pending", 1, available_at, "http_status:503"]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT status, attempt_count, available_at, last_error
               FROM outbox_messages
               WHERE id = $1
               """,
               [message_id]
             )

    assert DateTime.compare(available_at, DateTime.utc_now()) == :gt

    RedemptionsFixtures.scoped_query!(
      fixture,
      "UPDATE outbox_messages SET available_at = statement_timestamp() - interval '1 second' WHERE id = $1",
      [message_id]
    )

    assert {:ok, 1} = Delivery.run_once(fixture.scope, options)
    assert_receive {:failed_publish, ^message_id}

    assert %{rows: [["dead_letter", 2, nil, nil, "http_status:503"]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT status, attempt_count, locked_at, locked_by, last_error
               FROM outbox_messages
               WHERE id = $1
               """,
               [message_id]
             )

    assert {:ok, 0} = Delivery.run_once(fixture.scope, options)
  end

  test "a stale publishing claim is recovered after a worker crash" do
    fixture = RedemptionsFixtures.create!()
    message_id = emit_message!(fixture)

    RedemptionsFixtures.scoped_query!(
      fixture,
      """
      UPDATE outbox_messages
      SET status = 'publishing',
          attempt_count = 1,
          locked_at = statement_timestamp() - interval '2 minutes',
          locked_by = 'crashed-worker'
      WHERE id = $1
      """,
      [message_id]
    )

    assert {:ok, 1} =
             Delivery.run_once(fixture.scope,
               adapter: CaptureAdapter,
               adapter_options: [test_pid: self()],
               worker_id: "recovery-worker",
               batch_size: 1,
               lock_timeout_ms: 1_000
             )

    assert_receive {:published, %OutboxMessage{id: ^message_id}}

    assert %{rows: [["published", 2]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               "SELECT status, attempt_count FROM outbox_messages WHERE id = $1",
               [message_id]
             )
  end

  defp emit_message!(fixture) do
    {:ok, message_id} =
      Repo.transact_in_polo(fixture.scope, fn repo ->
        now = DateTime.utc_now(:microsecond)

        event =
          Events.emit!(repo, %{
            polo_id: fixture.ids.polo,
            aggregate_type: "test",
            aggregate_id: Ecto.UUID.generate(version: 7),
            aggregate_version: 1,
            event_type: "test.example",
            topic: "tests.example",
            message_key: "example-key",
            payload: %{"example" => true},
            occurred_at: now
          })

        message = Repo.get_by!(OutboxMessage, domain_event_id: event.id)
        {:ok, message.id}
      end)

    message_id
  end
end
