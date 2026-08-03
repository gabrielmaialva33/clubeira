defmodule Clubeira.Repo.Migrations.CreatePoloRoles do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:polo_roles, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false
      add :key, :citext, null: false
      add :name, :text, null: false
      add :status, :text, null: false, default: "active"

      timestamps(@timestamps_opts)
    end

    create unique_index(:polo_roles, [:polo_id, :key])
    create unique_index(:polo_roles, [:id, :polo_id], name: :polo_roles_id_polo_uidx)

    create constraint(:polo_roles, :polo_roles_status_check,
             check: "status IN ('active', 'retired')"
           )
  end
end
