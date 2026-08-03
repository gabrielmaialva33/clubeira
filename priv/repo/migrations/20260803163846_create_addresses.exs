defmodule Clubeira.Repo.Migrations.CreateAddresses do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:addresses, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :city_id, references(:cities, type: :uuid, on_delete: :restrict), null: false
      add :postal_code, :text
      add :street, :text, null: false
      add :number, :text
      add :complement, :text
      add :district, :text
      add :latitude, :decimal, precision: 9, scale: 6
      add :longitude, :decimal, precision: 9, scale: 6

      timestamps(@timestamps_opts)
    end

    create unique_index(:addresses, [:id, :city_id], name: :addresses_id_city_uidx)
    create index(:addresses, [:city_id, :postal_code])

    create constraint(:addresses, :addresses_latitude_check,
             check: "latitude IS NULL OR latitude BETWEEN -90 AND 90"
           )

    create constraint(:addresses, :addresses_longitude_check,
             check: "longitude IS NULL OR longitude BETWEEN -180 AND 180"
           )
  end
end
