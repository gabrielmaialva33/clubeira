defmodule Clubeira.Directory.PlaceOperator do
  @moduledoc """
  Records an organization's operating role at a place over time.
  """

  use Clubeira.Schema

  alias Clubeira.Directory.Organization
  alias Clubeira.Directory.Place
  alias Clubeira.Types.TstzRange

  schema "place_operators" do
    belongs_to :place, Place
    belongs_to :organization, Organization

    field :role, :string
    field :valid_during, TstzRange
    field :inserted_at, :utc_datetime_usec
  end
end
