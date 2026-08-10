defmodule Clubeira.Directory.PoloPlaceProfile do
  @moduledoc """
  The public, polo-owned publication of one participating place.

  Contact and schedule live here rather than on the global place identity so
  an administrator cannot change another polo's directory as a side effect.
  """

  use Clubeira.Schema

  alias Clubeira.Polos.Polo
  alias Clubeira.Polos.PoloPlace

  schema "polo_place_profiles" do
    belongs_to :polo, Polo
    belongs_to :polo_place, PoloPlace

    field :public_email, :string
    field :public_phone, :string
    field :revision, :integer

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          polo_id: Ecto.UUID.t(),
          polo_place_id: Ecto.UUID.t(),
          public_email: String.t(),
          public_phone: String.t(),
          revision: pos_integer(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
