defmodule Clubeira.Polos.PoloPlace do
  @moduledoc """
  Associates a place with a polo during a participation period.
  """

  use Clubeira.Schema

  alias Clubeira.Directory.City
  alias Clubeira.Directory.Place
  alias Clubeira.Polos.Polo
  alias Clubeira.Types.TstzRange

  schema "polo_places" do
    belongs_to :city, City
    belongs_to :polo, Polo
    belongs_to :place, Place

    field :participation_during, TstzRange
    field :status, :string

    timestamps()
  end
end
