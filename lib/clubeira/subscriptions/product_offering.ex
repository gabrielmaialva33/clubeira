defmodule Clubeira.Subscriptions.ProductOffering do
  @moduledoc """
  Stable sellable offer for a versioned access product.
  """

  use Clubeira.Schema

  alias Clubeira.Polos.Polo
  alias Clubeira.Subscriptions.AccessProductVersion

  schema "product_offerings" do
    belongs_to :polo, Polo
    belongs_to :access_product_version, AccessProductVersion

    field :edition_id, Ecto.UUID
    field :code, :string
    field :scope_kind, :string
    field :sales_channel, :string
    field :status, :string

    timestamps()
  end
end
