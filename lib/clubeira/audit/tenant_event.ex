defmodule Clubeira.Audit.TenantEvent do
  @moduledoc """
  Immutable tenant audit fact written beside the domain transaction.
  """

  use Clubeira.Schema

  schema "tenant_audit_events" do
    field :polo_id, Ecto.UUID
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
          polo_id: Ecto.UUID.t(),
          actor_user_id: Ecto.UUID.t() | nil,
          actor_kind: String.t(),
          action: String.t(),
          resource_type: String.t(),
          resource_id: Ecto.UUID.t() | nil,
          request_id: Ecto.UUID.t() | nil,
          correlation_id: Ecto.UUID.t() | nil,
          metadata: map(),
          occurred_at: DateTime.t(),
          inserted_at: DateTime.t()
        }
end
