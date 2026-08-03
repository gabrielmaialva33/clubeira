defmodule Clubeira.Repo.Migrations.CreatePoloPlaces do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:polo_places, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :city_id, :uuid, null: false

      add :polo_id,
          references(:polos,
            type: :uuid,
            with: [city_id: :city_id],
            name: :polo_places_polo_city_fkey,
            on_delete: :restrict
          ),
          null: false

      add :place_id,
          references(:places,
            type: :uuid,
            with: [city_id: :city_id],
            name: :polo_places_place_city_fkey,
            on_delete: :restrict
          ),
          null: false

      add :participation_during, :tstzrange, null: false
      add :status, :text, null: false, default: "active"

      timestamps(@timestamps_opts)
    end

    create unique_index(:polo_places, [:id, :polo_id], name: :polo_places_id_polo_uidx)
    create index(:polo_places, [:polo_id, :place_id])
    create index(:polo_places, [:place_id])

    create constraint(:polo_places, :polo_places_status_check,
             check: "status IN ('invited', 'active', 'suspended', 'retired')"
           )

    create constraint(:polo_places, :polo_places_participation_check,
             check:
               "NOT isempty(participation_during) AND NOT lower_inf(participation_during) AND lower_inc(participation_during) AND NOT upper_inc(participation_during)"
           )

    create constraint(:polo_places, :polo_places_no_overlap,
             exclude: "gist (polo_id WITH =, place_id WITH =, participation_during WITH &&)"
           )
  end
end
