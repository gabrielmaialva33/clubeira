defmodule Clubeira.Directory.Organization do
  @moduledoc """
  A legal or commercial organization in the partner network.
  """

  use Clubeira.Schema

  schema "organizations" do
    field :kind, :string
    field :legal_name, :string
    field :trade_name, :string
    field :country_code, :string
    field :status, :string

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          kind: String.t(),
          legal_name: String.t(),
          trade_name: String.t() | nil,
          country_code: String.t(),
          status: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
