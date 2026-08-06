defmodule Clubeira.Billing.Payment do
  @moduledoc """
  Settled or failed provider payment recorded against a payment intent.
  """

  use Clubeira.Schema

  alias Clubeira.Billing.MerchantAccount
  alias Clubeira.Billing.PaymentIntent
  alias Clubeira.Polos.Polo

  schema "payments" do
    belongs_to :polo, Polo
    belongs_to :payment_intent, PaymentIntent
    belongs_to :merchant_account, MerchantAccount

    field :provider_reference, :string
    field :currency, :string
    field :amount, :decimal
    field :status, :string
    field :authorized_at, :utc_datetime_usec
    field :captured_at, :utc_datetime_usec
    field :refunded_at, :utc_datetime_usec
    field :failed_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          polo_id: Ecto.UUID.t(),
          payment_intent_id: Ecto.UUID.t(),
          merchant_account_id: Ecto.UUID.t(),
          provider_reference: String.t(),
          currency: String.t(),
          amount: Decimal.t(),
          status: String.t(),
          authorized_at: DateTime.t() | nil,
          captured_at: DateTime.t() | nil,
          refunded_at: DateTime.t() | nil,
          failed_at: DateTime.t() | nil,
          inserted_at: DateTime.t()
        }
end
