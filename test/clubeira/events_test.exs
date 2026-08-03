defmodule Clubeira.EventsTest do
  use ExUnit.Case, async: true

  alias Clubeira.Events
  alias Clubeira.Repo

  test "requires the event and outbox message to be emitted inside one transaction" do
    assert_raise ArgumentError,
                 "domain events must be emitted inside a database transaction",
                 fn -> Events.emit!(Repo, %{}) end
  end
end
