defmodule Clubeira.Platform.Payment do
  @moduledoc "Provider payment applied to one platform invoice."

  use Clubeira.Schema

  alias Clubeira.Billing.MerchantAccount
  alias Clubeira.Platform.Invoice
  alias Clubeira.Polos.Polo

  schema "platform_payments" do
    belongs_to :polo, Polo
    belongs_to :platform_invoice, Invoice
    belongs_to :merchant_account, MerchantAccount

    field :provider_reference, :string
    field :currency, :string
    field :amount, :decimal
    field :status, :string
    field :paid_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          polo_id: Ecto.UUID.t(),
          platform_invoice_id: Ecto.UUID.t(),
          merchant_account_id: Ecto.UUID.t(),
          provider_reference: String.t(),
          currency: String.t(),
          amount: Decimal.t(),
          status: String.t(),
          paid_at: DateTime.t() | nil,
          inserted_at: DateTime.t()
        }
end
