defmodule Clubeira.Platform.Invoice do
  @moduledoc "Immutable platform billing statement for one polo period."

  use Clubeira.Schema

  alias Clubeira.Billing.MerchantAccount
  alias Clubeira.Platform.PoloSubscription
  alias Clubeira.Polos.Polo
  alias Clubeira.Types.TstzRange

  schema "platform_invoices" do
    belongs_to :polo, Polo
    belongs_to :polo_platform_subscription, PoloSubscription
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
          polo_platform_subscription_id: Ecto.UUID.t(),
          merchant_account_id: Ecto.UUID.t(),
          provider_reference: String.t(),
          invoice_number: String.t(),
          billing_period: Postgrex.Range.t(),
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
