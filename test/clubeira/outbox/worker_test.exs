defmodule Clubeira.Outbox.WorkerTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Events
  alias Clubeira.Events.OutboxMessage
  alias Clubeira.Outbox.Worker
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo

  defmodule CaptureAdapter do
    @moduledoc false

    def publish(message, options) do
      send(Keyword.fetch!(options, :test_pid), {:worker_published, message.id})
      :ok
    end
  end

  test "discovers every polo and drains one isolated batch on each tick" do
    fixture = RedemptionsFixtures.create!()
    message_id = emit_message!(fixture)

    worker =
      start_supervised!({Worker,
       name: nil,
       initial_delay_ms: 60_000,
       interval_ms: 60_000,
       adapter: CaptureAdapter,
       adapter_options: [test_pid: self()],
       worker_id: "worker-test",
       batch_size: 10,
       lock_timeout_ms: 1_000,
       max_attempts: 3,
       retry_base_ms: 100,
       retry_max_ms: 1_000})

    send(worker, :publish_outbox)

    assert_receive {:worker_published, ^message_id}
    _state = :sys.get_state(worker)

    assert %{rows: [["published", 1]]} =
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
            event_type: "test.worker",
            topic: "tests.worker",
            message_key: "worker-key",
            payload: %{},
            occurred_at: now
          })

        {:ok, Repo.get_by!(OutboxMessage, domain_event_id: event.id).id}
      end)

    message_id
  end
end
