defmodule Clubeira.Repo.Migrations.CreatePlaces do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:places, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :city_id, references(:cities, type: :uuid, on_delete: :restrict), null: false

      add :address_id,
          references(:addresses,
            type: :uuid,
            with: [city_id: :city_id],
            name: :places_address_city_fkey,
            on_delete: :restrict
          ),
          null: false

      add :slug, :citext, null: false
      add :name, :text, null: false
      add :timezone, :text, null: false
      add :status, :text, null: false, default: "active"

      timestamps(@timestamps_opts)
    end

    create unique_index(:places, [:id, :city_id], name: :places_id_city_uidx)
    create unique_index(:places, [:city_id, :slug])
    create index(:places, [:address_id])

    create constraint(:places, :places_status_check,
             check: "status IN ('draft', 'active', 'temporarily_closed', 'retired')"
           )
  end
end
