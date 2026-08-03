defmodule Clubeira.Repo.Migrations.CreateOrganizationRoles do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:organization_roles, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")

      add :organization_id, references(:organizations, type: :uuid, on_delete: :restrict),
        null: false

      add :key, :citext, null: false
      add :name, :text, null: false
      add :status, :text, null: false, default: "active"

      timestamps(@timestamps_opts)
    end

    create unique_index(:organization_roles, [:organization_id, :key])

    create unique_index(:organization_roles, [:id, :organization_id],
             name: :organization_roles_id_org_uidx
           )

    create constraint(:organization_roles, :organization_roles_status_check,
             check: "status IN ('active', 'retired')"
           )
  end
end
