defmodule Clubeira.Events.DomainEvent do
  @moduledoc """
  Immutable event emitted by a committed domain state transition.
  """

  use Clubeira.Schema

  schema "domain_events" do
    field :polo_id, Ecto.UUID
    field :aggregate_type, :string
    field :aggregate_id, Ecto.UUID
    field :aggregate_version, :integer
    field :event_type, :string
    field :payload, :map
    field :metadata, :map
    field :occurred_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          polo_id: Ecto.UUID.t(),
          aggregate_type: String.t(),
          aggregate_id: Ecto.UUID.t(),
          aggregate_version: pos_integer(),
          event_type: String.t(),
          payload: map(),
          metadata: map(),
          occurred_at: DateTime.t(),
          inserted_at: DateTime.t()
        }
end
