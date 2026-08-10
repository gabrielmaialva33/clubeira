defmodule Clubeira.Platform.Feature do
  @moduledoc "Global feature identity reusable across versioned platform plans."

  use Clubeira.Schema

  schema "platform_features" do
    field :key, :string
    field :name, :string
    field :value_kind, :string
    field :status, :string

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          key: String.t(),
          name: String.t(),
          value_kind: String.t(),
          status: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
