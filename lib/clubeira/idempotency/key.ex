defmodule Clubeira.Idempotency.Key do
  @moduledoc """
  Tenant-scoped idempotency state for an externally retryable command.
  """

  use Clubeira.Schema

  schema "tenant_idempotency_keys" do
    field :polo_id, Ecto.UUID
    field :user_id, Ecto.UUID
    field :scope, :string
    field :idempotency_key, :string
    field :request_sha256, :binary
    field :status, :string
    field :response_status, :integer
    field :response_body, :map
    field :resource_type, :string
    field :resource_id, Ecto.UUID
    field :expires_at, :utc_datetime_usec

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          polo_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t() | nil,
          scope: String.t(),
          idempotency_key: String.t(),
          request_sha256: binary(),
          status: String.t(),
          response_status: non_neg_integer() | nil,
          response_body: map() | nil,
          resource_type: String.t() | nil,
          resource_id: Ecto.UUID.t() | nil,
          expires_at: DateTime.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
