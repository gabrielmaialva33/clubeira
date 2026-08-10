defmodule Clubeira.Directory.PoloPlaceProfileCategory do
  @moduledoc """
  Selects a curated global category for one polo-scoped place profile.
  """

  use Clubeira.Schema

  alias Clubeira.Directory.PlaceCategory
  alias Clubeira.Directory.PoloPlaceProfile
  alias Clubeira.Polos.Polo

  @primary_key false

  schema "polo_place_profile_categories" do
    belongs_to :polo, Polo, primary_key: true
    belongs_to :polo_place_profile, PoloPlaceProfile, primary_key: true
    belongs_to :place_category, PlaceCategory, primary_key: true

    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          polo_id: Ecto.UUID.t(),
          polo_place_profile_id: Ecto.UUID.t(),
          place_category_id: Ecto.UUID.t(),
          inserted_at: DateTime.t()
        }
end
