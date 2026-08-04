defmodule Clubeira.Repo.Migrations.CreatePolos do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:polos, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :city_id, references(:cities, type: :uuid, on_delete: :restrict), null: false
      add :name, :text, null: false

      add :timezone,
          references(:time_zones,
            column: :name,
            type: :text,
            name: :polos_timezone_fkey,
            on_delete: :restrict
          ),
          null: false

      add :status, :text, null: false, default: "draft"

      timestamps(@timestamps_opts)
    end

    create unique_index(:polos, [:city_id])
    create unique_index(:polos, [:id, :city_id], name: :polos_id_city_uidx)

    create constraint(:polos, :polos_status_check,
             check: "status IN ('draft', 'active', 'suspended', 'retired')"
           )
  end
end
