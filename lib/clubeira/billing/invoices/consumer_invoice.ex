defmodule Clubeira.Billing.ConsumerInvoice do
  @moduledoc """
  A consumer-facing invoice derived from an order or recurring charge.
  """

  use Clubeira.Schema

  alias Clubeira.Billing.BillingAgreement
  alias Clubeira.Billing.MerchantAccount
  alias Clubeira.Polos.Polo
  alias Clubeira.Subscriptions.Order
  alias Clubeira.Types.TstzRange

  schema "consumer_invoices" do
    belongs_to :polo, Polo
    belongs_to :billing_agreement, BillingAgreement
    belongs_to :order, Order
    belongs_to :merchant_account, MerchantAccount

    field :provider_reference, :string
    field :invoice_number, :string
    field :billing_period, TstzRange
    field :currency, :string
    field :subtotal_amount, :decimal
    field :discount_amount, :decimal
    field :total_amount, :decimal
    field :status, :string
    field :issued_at, :utc_datetime_usec
    field :due_at, :utc_datetime_usec
    field :paid_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          polo_id: Ecto.UUID.t(),
          billing_agreement_id: Ecto.UUID.t() | nil,
          order_id: Ecto.UUID.t() | nil,
          merchant_account_id: Ecto.UUID.t(),
          provider_reference: String.t(),
          invoice_number: String.t(),
          billing_period: Postgrex.Range.t() | nil,
          currency: String.t(),
          subtotal_amount: Decimal.t(),
          discount_amount: Decimal.t(),
          total_amount: Decimal.t(),
          status: String.t(),
          issued_at: DateTime.t() | nil,
          due_at: DateTime.t() | nil,
          paid_at: DateTime.t() | nil,
          inserted_at: DateTime.t()
        }
end
