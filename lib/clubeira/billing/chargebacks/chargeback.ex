defmodule Clubeira.Billing.Chargeback do
  @moduledoc """
  Provider-owned dispute lifecycle for one captured payment.

  Open disputes suspend access. A provider win restores it; a final loss
  revokes the remaining entitlement balance without deleting its ledger.
  """

  use Clubeira.Schema

  alias Clubeira.Billing.Payment
  alias Clubeira.Polos.Polo

  schema "chargebacks" do
    belongs_to :polo, Polo
    belongs_to :payment, Payment

    field :provider_reference, :string
    field :amount, :decimal
    field :reason_code, :string
    field :status, :string
    field :opened_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          polo_id: Ecto.UUID.t(),
          payment_id: Ecto.UUID.t(),
          provider_reference: String.t(),
          amount: Decimal.t(),
          reason_code: String.t() | nil,
          status: String.t(),
          opened_at: DateTime.t(),
          closed_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
