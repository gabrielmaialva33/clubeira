defmodule Clubeira.Billing.PaymentIntent do
  @moduledoc """
  Provider-neutral payment attempt for one tenant order.
  """

  use Clubeira.Schema

  alias Clubeira.Billing.MerchantAccount
  alias Clubeira.Polos.Polo
  alias Clubeira.Subscriptions.Order

  schema "payment_intents" do
    belongs_to :polo, Polo
    belongs_to :order, Order
    belongs_to :merchant_account, MerchantAccount

    field :idempotency_key, :string
    field :provider_reference, :string
    field :payment_method, :string
    field :currency, :string
    field :amount, :decimal
    field :status, :string
    field :expires_at, :utc_datetime_usec
    field :next_action, :map, default: %{}

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          polo_id: Ecto.UUID.t(),
          order_id: Ecto.UUID.t(),
          merchant_account_id: Ecto.UUID.t(),
          idempotency_key: String.t(),
          provider_reference: String.t() | nil,
          payment_method: String.t() | nil,
          currency: String.t(),
          amount: Decimal.t(),
          status: String.t(),
          expires_at: DateTime.t() | nil,
          next_action: map(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
