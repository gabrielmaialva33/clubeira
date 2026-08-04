defmodule Clubeira.Subscriptions.OrderItem do
  @moduledoc """
  Immutable price selection captured by an order.
  """

  use Clubeira.Schema

  alias Clubeira.Polos.Polo
  alias Clubeira.Subscriptions.OfferingPrice
  alias Clubeira.Subscriptions.Order
  alias Clubeira.Subscriptions.ProductOfferingVersion

  schema "order_items" do
    belongs_to :polo, Polo
    belongs_to :order, Order
    belongs_to :product_offering_version, ProductOfferingVersion
    belongs_to :offering_price, OfferingPrice

    field :quantity, :integer
    field :unit_amount, :decimal
    field :total_amount, :decimal
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          polo_id: Ecto.UUID.t(),
          order_id: Ecto.UUID.t(),
          product_offering_version_id: Ecto.UUID.t(),
          offering_price_id: Ecto.UUID.t(),
          quantity: pos_integer(),
          unit_amount: Decimal.t(),
          total_amount: Decimal.t(),
          inserted_at: DateTime.t()
        }
end
