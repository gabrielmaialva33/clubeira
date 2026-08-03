defmodule Clubeira.Repo.Migrations.CreatePlaceStaffRoles do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:place_staff_roles, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :place_id, references(:places, type: :uuid, on_delete: :restrict), null: false
      add :key, :citext, null: false
      add :name, :text, null: false
      add :status, :text, null: false, default: "active"

      timestamps(@timestamps_opts)
    end

    create unique_index(:place_staff_roles, [:place_id, :key])

    create unique_index(:place_staff_roles, [:id, :place_id],
             name: :place_staff_roles_id_place_uidx
           )

    create constraint(:place_staff_roles, :place_staff_roles_status_check,
             check: "status IN ('active', 'retired')"
           )
  end
end
