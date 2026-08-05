defmodule Clubeira.Redemptions.ValidationPoint do
  @moduledoc """
  Tenant validation endpoint controlled by a participating merchant.
  """

  use Clubeira.Schema

  schema "validation_points" do
    field :polo_id, Ecto.UUID
    field :polo_place_id, Ecto.UUID
    field :name, :string
    field :kind, :string
    field :status, :string

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          polo_id: Ecto.UUID.t(),
          polo_place_id: Ecto.UUID.t(),
          name: String.t(),
          kind: String.t(),
          status: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
