defmodule Clubeira.Directory.Address do
  @moduledoc """
  A physical address in the geographic directory.
  """

  use Clubeira.Schema

  alias Clubeira.Directory.City

  schema "addresses" do
    belongs_to :city, City

    field :postal_code, :string
    field :street, :string
    field :number, :string
    field :complement, :string
    field :district, :string
    field :latitude, :decimal
    field :longitude, :decimal

    timestamps()
  end
end
