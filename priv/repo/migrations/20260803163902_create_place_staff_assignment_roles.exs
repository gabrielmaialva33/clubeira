defmodule Clubeira.Repo.Migrations.CreatePlaceStaffAssignmentRoles do
  use Ecto.Migration

  def change do
    create table(:place_staff_assignment_roles, primary_key: false) do
      add :place_id, references(:places, type: :uuid, on_delete: :restrict),
        primary_key: true,
        null: false

      add :place_staff_assignment_id,
          references(:place_staff_assignments,
            type: :uuid,
            with: [place_id: :place_id],
            name: :place_staff_assignment_roles_assignment_fkey,
            on_delete: :restrict
          ),
          primary_key: true,
          null: false

      add :place_staff_role_id,
          references(:place_staff_roles,
            type: :uuid,
            with: [place_id: :place_id],
            name: :place_staff_assignment_roles_role_fkey,
            on_delete: :restrict
          ),
          primary_key: true,
          null: false

      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:place_staff_assignment_roles, [:place_staff_role_id])
  end
end
