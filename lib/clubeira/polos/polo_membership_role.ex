defmodule Clubeira.Polos.PoloMembershipRole do
  @moduledoc """
  Tenant-safe assignment of a polo role to a polo membership.
  """

  use Ecto.Schema

  @primary_key false

  schema "polo_membership_roles" do
    field :polo_id, Ecto.UUID, primary_key: true
    field :polo_membership_id, Ecto.UUID, primary_key: true
    field :polo_role_id, Ecto.UUID, primary_key: true
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          polo_id: Ecto.UUID.t(),
          polo_membership_id: Ecto.UUID.t(),
          polo_role_id: Ecto.UUID.t(),
          inserted_at: DateTime.t()
        }
end
