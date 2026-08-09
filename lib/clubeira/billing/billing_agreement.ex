defmodule Clubeira.Billing.BillingAgreement do
  @moduledoc """
  A provider-backed authorization for recurring consumer charges.
  """

  use Clubeira.Schema

  alias Clubeira.Accounts.User
  alias Clubeira.Billing.MerchantAccount
  alias Clubeira.Polos.Polo
  alias Clubeira.Subscriptions.OrderItem
  alias Clubeira.Subscriptions.ProductOfferingVersion
  alias Clubeira.Types.TstzRange

  schema "billing_agreements" do
    belongs_to :polo, Polo
    belongs_to :user, User
    belongs_to :product_offering_version, ProductOfferingVersion
    belongs_to :order_item, OrderItem
    belongs_to :merchant_account, MerchantAccount

    field :provider_reference, :string
    field :idempotency_key, :string
    field :request_sha256, :binary
    field :status, :string
    field :current_period, TstzRange
    field :next_charge_at, :utc_datetime_usec
    field :next_action, :map, default: %{}
    field :cancelled_at, :utc_datetime_usec

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          polo_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          product_offering_version_id: Ecto.UUID.t(),
          order_item_id: Ecto.UUID.t() | nil,
          merchant_account_id: Ecto.UUID.t(),
          provider_reference: String.t() | nil,
          idempotency_key: String.t() | nil,
          request_sha256: binary() | nil,
          status: String.t(),
          current_period: Postgrex.Range.t() | nil,
          next_charge_at: DateTime.t() | nil,
          next_action: map(),
          cancelled_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
