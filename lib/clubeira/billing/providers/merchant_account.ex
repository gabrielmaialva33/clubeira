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

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          payment_provider_id: Ecto.UUID.t(),
          kind: String.t(),
          name: String.t(),
          provider_account_reference: String.t(),
          status: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
