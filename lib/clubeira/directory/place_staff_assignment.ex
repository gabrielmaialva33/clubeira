defmodule Clubeira.Directory.PlaceStaffAssignment do
  @moduledoc """
  Time-bounded staff affiliation between an organization member and a place.
  """

  use Clubeira.Schema

  alias Clubeira.Accounts.User
  alias Clubeira.Directory.Organization
  alias Clubeira.Directory.OrganizationMembership
  alias Clubeira.Directory.Place
  alias Clubeira.Types.TstzRange

  schema "place_staff_assignments" do
    belongs_to :place, Place
    belongs_to :organization, Organization
    belongs_to :user, User
    belongs_to :organization_membership, OrganizationMembership

    field :valid_during, TstzRange
    field :status, :string

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          place_id: Ecto.UUID.t(),
          organization_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          organization_membership_id: Ecto.UUID.t(),
          valid_during: Postgrex.Range.t(),
          status: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
