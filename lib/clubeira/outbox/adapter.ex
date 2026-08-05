defmodule Clubeira.Outbox.Adapter do
  @moduledoc """
  Delivery boundary for durable outbox messages.

  Adapters must be idempotent by `message.id` because delivery is at least once.
  Error reasons must not contain credentials or response bodies.
  """

  alias Clubeira.Events.OutboxMessage

  @type error_reason :: atom() | {:http_status, pos_integer()} | {:transport, atom()}

  @callback publish(OutboxMessage.t(), keyword()) :: :ok | {:error, error_reason()}
end
