defmodule Clubeira.Catalog.EditionPlace do
  @moduledoc """
  Binds a catalog edition to an eligible place in its polo.
  """

  use Clubeira.Schema

  alias Clubeira.Catalog.Edition
  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloPlace

  @primary_key false

  schema "edition_places" do
    belongs_to :polo, Polo, primary_key: true
    belongs_to :edition, Edition, primary_key: true
    belongs_to :polo_place, PoloPlace, primary_key: true

    field :inserted_at, :utc_datetime_usec
  end
end
