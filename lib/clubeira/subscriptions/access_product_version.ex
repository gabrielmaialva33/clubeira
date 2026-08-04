defmodule Clubeira.Subscriptions.AccessProductVersion do
  @moduledoc """
  Immutable published description of a subscription product.
  """

  use Clubeira.Schema

  alias Clubeira.Polos.Polo
  alias Clubeira.Subscriptions.AccessProduct

  schema "access_product_versions" do
    belongs_to :polo, Polo
    belongs_to :access_product, AccessProduct

    field :version, :integer
    field :name, :string
    field :description, :string
    field :status, :string
    field :published_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end
end
