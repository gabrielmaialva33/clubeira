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

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          domain_event_id: Ecto.UUID.t(),
          topic: String.t(),
          message_key: String.t(),
          payload: map(),
          status: String.t(),
          attempt_count: non_neg_integer(),
          available_at: DateTime.t(),
          locked_at: DateTime.t() | nil,
          locked_by: String.t() | nil,
          published_at: DateTime.t() | nil,
          last_error: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
