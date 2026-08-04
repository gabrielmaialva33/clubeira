defmodule Clubeira.Repo.Migrations.CreateCities do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:cities, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :country_code, :string, size: 2, null: false
      add :subdivision_code, :text, null: false
      add :external_code, :text
      add :name, :text, null: false

      add :timezone,
          references(:time_zones,
            column: :name,
            type: :text,
            name: :cities_timezone_fkey,
            on_delete: :restrict
          ),
          null: false

      add :status, :text, null: false, default: "active"

      timestamps(@timestamps_opts)
    end

    create unique_index(:cities, [:country_code, :subdivision_code, :external_code],
             where: "external_code IS NOT NULL",
             name: :cities_external_code_uidx
           )

    create index(:cities, [:country_code, :subdivision_code, :name])

    create constraint(:cities, :cities_country_code_check,
             check: "country_code = upper(country_code) AND char_length(country_code) = 2"
           )

    create constraint(:cities, :cities_status_check, check: "status IN ('active', 'inactive')")
  end
end
