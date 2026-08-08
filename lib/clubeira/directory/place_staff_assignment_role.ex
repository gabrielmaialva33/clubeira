defmodule Clubeira.Directory.PlaceStaffAssignmentRole do
  @moduledoc """
  Assignment of a place role to a place staff affiliation.
  """

  use Ecto.Schema

  @primary_key false

  schema "place_staff_assignment_roles" do
    field :place_id, Ecto.UUID, primary_key: true
    field :place_staff_assignment_id, Ecto.UUID, primary_key: true
    field :place_staff_role_id, Ecto.UUID, primary_key: true
    field :inserted_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{
          place_id: Ecto.UUID.t(),
          place_staff_assignment_id: Ecto.UUID.t(),
          place_staff_role_id: Ecto.UUID.t(),
          inserted_at: DateTime.t()
        }
end
