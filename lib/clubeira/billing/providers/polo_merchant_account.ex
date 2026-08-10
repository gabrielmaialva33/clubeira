defmodule Clubeira.Billing.PoloMerchantAccount do
  @moduledoc """
  Time-bounded authorization for a polo to collect through a global merchant account.
  """

  use Ecto.Schema

  alias Clubeira.Billing.MerchantAccount
  alias Clubeira.Billing.PaymentProvider
  alias Clubeira.Polos.Polo
  alias Clubeira.Types.TstzRange

  @primary_key false
  @foreign_key_type Ecto.UUID

  schema "polo_merchant_accounts" do
    belongs_to :polo, Polo, primary_key: true
    belongs_to :merchant_account, MerchantAccount, primary_key: true
    belongs_to :payment_provider, PaymentProvider

    field :role, :string
    field :valid_during, TstzRange
    field :inserted_at, :utc_datetime_usec
  end
end
