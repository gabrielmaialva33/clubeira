defmodule Clubeira.Directory.PlaceStaffRole do
  @moduledoc """
  Named authorization role scoped to one commercial place.
  """

  use Clubeira.Schema

  alias Clubeira.Directory.Place

  schema "place_staff_roles" do
    belongs_to :place, Place

    field :key, :string
    field :name, :string
    field :status, :string

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          place_id: Ecto.UUID.t(),
          key: String.t(),
          name: String.t(),
          status: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
