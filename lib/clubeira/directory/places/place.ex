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

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          city_id: Ecto.UUID.t(),
          address_id: Ecto.UUID.t(),
          slug: String.t(),
          name: String.t(),
          timezone: String.t(),
          status: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
