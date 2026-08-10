defmodule Clubeira.Directory.PlaceCategory do
  @moduledoc """
  A global, curated category available to polo-scoped place profiles.
  """

  use Clubeira.Schema

  schema "place_categories" do
    field :key, :string
    field :name, :string
    field :status, :string
    field :display_order, :integer

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          key: String.t(),
          name: String.t(),
          status: String.t(),
          display_order: non_neg_integer(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
