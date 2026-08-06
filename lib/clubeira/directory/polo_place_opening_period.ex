defmodule Clubeira.Directory.PoloPlaceOpeningPeriod do
  @moduledoc """
  A normalized weekly window or date-specific schedule exception.
  """

  use Clubeira.Schema

  alias Clubeira.Directory.PoloPlaceProfile
  alias Clubeira.Polos.Polo

  schema "polo_place_opening_periods" do
    belongs_to :polo, Polo
    belongs_to :polo_place_profile, PoloPlaceProfile

    field :kind, :string
    field :weekday, :integer
    field :local_date, :date
    field :opens_at, :time
    field :closes_at, :time
    field :closes_next_day, :boolean

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          polo_id: Ecto.UUID.t(),
          polo_place_profile_id: Ecto.UUID.t(),
          kind: String.t(),
          weekday: 1..7 | nil,
          local_date: Date.t() | nil,
          opens_at: Time.t() | nil,
          closes_at: Time.t() | nil,
          closes_next_day: boolean(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
