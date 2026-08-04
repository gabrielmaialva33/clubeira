defmodule Clubeira.Audit.SystemEvent do
  @moduledoc """
  Immutable audit fact for global operations such as authentication.
  """

  use Clubeira.Schema

  schema "system_audit_events" do
    field :actor_user_id, Ecto.UUID
    field :actor_kind, :string
    field :action, :string
    field :resource_type, :string
    field :resource_id, Ecto.UUID
    field :request_id, Ecto.UUID
    field :correlation_id, Ecto.UUID
    field :metadata, :map
    field :occurred_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          actor_user_id: Ecto.UUID.t() | nil,
          actor_kind: String.t(),
          action: String.t(),
          resource_type: String.t(),
          resource_id: Ecto.UUID.t() | nil,
          request_id: Ecto.UUID.t(),
          correlation_id: Ecto.UUID.t(),
          metadata: map(),
          occurred_at: DateTime.t(),
          inserted_at: DateTime.t()
        }
end
