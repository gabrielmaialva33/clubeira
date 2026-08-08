defmodule Clubeira.Directory.OrganizationRole do
  @moduledoc """
  Named authorization role inside one partner organization.
  """

  use Clubeira.Schema

  alias Clubeira.Directory.Organization

  schema "organization_roles" do
    belongs_to :organization, Organization

    field :key, :string
    field :name, :string
    field :status, :string

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          key: String.t(),
          name: String.t(),
          status: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
