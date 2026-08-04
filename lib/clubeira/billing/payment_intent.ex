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
    field :currency, :string
    field :amount, :decimal
    field :status, :string
    field :expires_at, :utc_datetime_usec

    timestamps()
  end
end
