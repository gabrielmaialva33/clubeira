defmodule Clubeira.Subscriptions.AccessContract do
  @moduledoc """
  A member's independent commercial access contract within one polo.
  """

  use Clubeira.Schema

  alias Clubeira.Accounts.User
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloPolicyVersion
  alias Clubeira.Subscriptions.OrderItem
  alias Clubeira.Subscriptions.ProductOfferingVersion

  schema "access_contracts" do
    belongs_to :polo, Polo
    belongs_to :purchaser_user, User
    belongs_to :order_item, OrderItem
    belongs_to :product_offering_version, ProductOfferingVersion
    belongs_to :polo_policy_version, PoloPolicyVersion

    field :billing_agreement_id, Ecto.UUID

    field :status, :string
    field :starts_at, :utc_datetime_usec
    field :activated_at, :utc_datetime_usec
    field :ends_at, :utc_datetime_usec
    field :cancelled_at, :utc_datetime_usec

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          polo_id: Ecto.UUID.t(),
          purchaser_user_id: Ecto.UUID.t(),
          order_item_id: Ecto.UUID.t(),
          product_offering_version_id: Ecto.UUID.t(),
          polo_policy_version_id: Ecto.UUID.t(),
          billing_agreement_id: Ecto.UUID.t() | nil,
          status: String.t(),
          starts_at: DateTime.t() | nil,
          activated_at: DateTime.t() | nil,
          ends_at: DateTime.t() | nil,
          cancelled_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
