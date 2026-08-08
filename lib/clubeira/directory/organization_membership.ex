defmodule Clubeira.Directory.OrganizationMembership do
  @moduledoc """
  Time-bounded affiliation between one account and one partner organization.
  """

  use Clubeira.Schema

  alias Clubeira.Accounts.User
  alias Clubeira.Directory.Organization
  alias Clubeira.Types.TstzRange

  schema "organization_memberships" do
    belongs_to :organization, Organization
    belongs_to :user, User

    field :valid_during, TstzRange
    field :status, :string

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          valid_during: Postgrex.Range.t(),
          status: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
