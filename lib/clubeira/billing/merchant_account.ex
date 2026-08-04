defmodule Clubeira.Billing.MerchantAccount do
  @moduledoc """
  Global provider account used to collect consumer or platform payments.
  """

  use Clubeira.Schema

  alias Clubeira.Billing.PaymentProvider

  schema "merchant_accounts" do
    belongs_to :payment_provider, PaymentProvider

    field :kind, :string
    field :name, :string
    field :provider_account_reference, :string
    field :status, :string

    timestamps()
  end
end
