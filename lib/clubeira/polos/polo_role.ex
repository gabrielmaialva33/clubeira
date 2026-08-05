defmodule Clubeira.Polos.PoloRole do
  @moduledoc """
  Named authorization role managed inside one polo.
  """

  use Clubeira.Schema

  schema "polo_roles" do
    field :polo_id, Ecto.UUID
    field :key, :string
    field :name, :string
    field :status, :string

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          polo_id: Ecto.UUID.t(),
          key: String.t(),
          name: String.t(),
          status: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
