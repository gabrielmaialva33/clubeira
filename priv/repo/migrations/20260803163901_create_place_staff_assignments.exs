defmodule Clubeira.Repo.Migrations.CreatePlaceStaffAssignments do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:place_staff_assignments, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :place_id, references(:places, type: :uuid, on_delete: :restrict), null: false

      add :organization_id, references(:organizations, type: :uuid, on_delete: :restrict),
        null: false

      add :user_id, references(:users, type: :uuid, on_delete: :restrict), null: false

      add :organization_membership_id,
          references(:organization_memberships,
            type: :uuid,
            with: [organization_id: :organization_id, user_id: :user_id],
            name: :place_staff_assignments_membership_fkey,
            on_delete: :restrict
          ),
          null: false

      add :valid_during, :tstzrange, null: false
      add :status, :text, null: false, default: "active"

      timestamps(@timestamps_opts)
    end

    create unique_index(:place_staff_assignments, [:id, :place_id],
             name: :place_staff_assignments_id_place_uidx
           )

    create index(:place_staff_assignments, [:place_id, :user_id])
    create index(:place_staff_assignments, [:organization_membership_id])

    create constraint(:place_staff_assignments, :place_staff_assignments_status_check,
             check: "status IN ('active', 'suspended', 'revoked')"
           )

    create constraint(:place_staff_assignments, :place_staff_assignments_valid_during_check,
             check:
               "NOT isempty(valid_during) AND NOT lower_inf(valid_during) AND lower_inc(valid_during) AND NOT upper_inc(valid_during)"
           )

    create constraint(:place_staff_assignments, :place_staff_assignments_no_overlap,
             exclude: "gist (place_id WITH =, user_id WITH =, valid_during WITH &&)"
           )
  end
end
