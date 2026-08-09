defmodule Clubeira.Platform.Plan do
  @moduledoc "Stable identity of a Clubeira SaaS plan."

  use Clubeira.Schema

  schema "platform_plans" do
    field :code, :string
    field :name, :string
    field :status, :string

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          code: String.t(),
          name: String.t(),
          status: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
