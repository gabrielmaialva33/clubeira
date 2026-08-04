defmodule Clubeira.Subscriptions.OfferingPrice do
  @moduledoc """
  Versioned price and billing cadence for a product offering.
  """

  use Clubeira.Schema

  alias Clubeira.Polos.Polo
  alias Clubeira.Subscriptions.ProductOfferingVersion
  alias Clubeira.Types.TstzRange

  schema "offering_prices" do
    belongs_to :polo, Polo
    belongs_to :product_offering_version, ProductOfferingVersion

    field :price_key, :string
    field :currency, :string
    field :amount, :decimal
    field :billing_model, :string
    field :billing_interval_unit, :string
    field :billing_interval_count, :integer
    field :installments, :integer
    field :valid_during, TstzRange
    field :inserted_at, :utc_datetime_usec
  end
end
