defmodule Clubeira.Events.OutboxMessage do
  @moduledoc """
  Durable message derived from a domain event for post-commit publication.
  """

  use Clubeira.Schema

  schema "outbox_messages" do
    field :domain_event_id, Ecto.UUID
    field :topic, :string
    field :message_key, :string
    field :payload, :map
    field :status, :string
    field :attempt_count, :integer
    field :available_at, :utc_datetime_usec
    field :locked_at, :utc_datetime_usec
    field :locked_by, :string
    field :published_at, :utc_datetime_usec
    field :last_error, :string

    timestamps()
  end
end
