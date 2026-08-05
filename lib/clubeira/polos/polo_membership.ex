defmodule Clubeira.Polos.PoloMembership do
  @moduledoc """
  Time-bounded staff membership inside one polo.
  """

  use Clubeira.Schema

  alias Clubeira.Types.TstzRange

  schema "polo_memberships" do
    field :polo_id, Ecto.UUID
    field :user_id, Ecto.UUID
    field :valid_during, TstzRange
    field :status, :string

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          polo_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          valid_during: Postgrex.Range.t(),
          status: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
