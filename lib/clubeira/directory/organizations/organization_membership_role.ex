defmodule Clubeira.Directory.OrganizationMembershipRole do
  @moduledoc """
  Assignment of an organization role to an organization membership.
  """

  use Ecto.Schema

  @primary_key false

  schema "organization_membership_roles" do
    field :organization_id, Ecto.UUID, primary_key: true
    field :organization_membership_id, Ecto.UUID, primary_key: true
    field :organization_role_id, Ecto.UUID, primary_key: true
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          organization_id: Ecto.UUID.t(),
          organization_membership_id: Ecto.UUID.t(),
          organization_role_id: Ecto.UUID.t(),
          inserted_at: DateTime.t()
        }
end
