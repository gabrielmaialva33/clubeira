defmodule Clubeira.Billing.Refund do
  @moduledoc """
  Full reversal of one captured payment, preserving the original financial history.
  """

  use Clubeira.Schema

  alias Clubeira.Accounts.User
  alias Clubeira.Billing.Payment
  alias Clubeira.Polos.Polo

  schema "refunds" do
    belongs_to :polo, Polo
    belongs_to :payment, Payment
    belongs_to :requested_by_user, User

    field :provider_reference, :string
    field :amount, :decimal
    field :reason, :string
    field :status, :string
    field :idempotency_key, :string
    field :request_sha256, :binary
    field :failure_reason, :string
    field :requested_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          polo_id: Ecto.UUID.t(),
          payment_id: Ecto.UUID.t(),
          requested_by_user_id: Ecto.UUID.t() | nil,
          provider_reference: String.t() | nil,
          amount: Decimal.t(),
          reason: String.t(),
          status: String.t(),
          idempotency_key: String.t() | nil,
          request_sha256: binary() | nil,
          failure_reason: String.t() | nil,
          requested_at: DateTime.t(),
          completed_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
