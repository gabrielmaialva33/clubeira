defmodule Clubeira.Directory.PlaceBrand do
  @moduledoc """
  Associates a place with a brand and role during a validity period.
  """

  use Clubeira.Schema

  alias Clubeira.Directory.Brand
  alias Clubeira.Directory.Place
  alias Clubeira.Types.TstzRange

  schema "place_brands" do
    belongs_to :place, Place
    belongs_to :brand, Brand

    field :role, :string
    field :valid_during, TstzRange
    field :inserted_at, :utc_datetime_usec
  end
end
