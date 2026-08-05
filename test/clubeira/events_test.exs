defmodule Clubeira.EventsTest do
  use ExUnit.Case, async: true

  alias Clubeira.Events
  alias Clubeira.Repo

  test "requires the event and outbox message to be emitted inside one transaction" do
    attributes = %{
      polo_id: Ecto.UUID.generate(version: 7),
      aggregate_type: "test",
      aggregate_id: Ecto.UUID.generate(version: 7),
      aggregate_version: 1,
      event_type: "test.emitted",
      topic: "test.events",
      message_key: "test",
      payload: %{},
      occurred_at: DateTime.utc_now(:microsecond)
    }

    assert_raise ArgumentError,
                 "domain events must be emitted inside a database transaction",
                 fn -> Events.emit!(Repo, attributes) end
  end
end
