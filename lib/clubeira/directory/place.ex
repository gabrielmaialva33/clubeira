defmodule Clubeira.Directory.Place do
  @moduledoc """
  A physical establishment where members can redeem benefits.
  """

  use Clubeira.Schema

  alias Clubeira.Directory.Address
  alias Clubeira.Directory.City

  schema "places" do
    belongs_to :city, City
    belongs_to :address, Address

    field :slug, :string
    field :name, :string
    field :timezone, :string
    field :status, :string

    timestamps()
  end
end
