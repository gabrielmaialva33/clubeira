defmodule Clubeira.Subscriptions.AccessProduct do
  @moduledoc """
  Stable identity of a subscription product within one polo.
  """

  use Clubeira.Schema

  alias Clubeira.Polos.Polo

  schema "access_products" do
    belongs_to :polo, Polo

    field :code, :string
    field :name, :string
    field :status, :string

    timestamps()
  end
end
