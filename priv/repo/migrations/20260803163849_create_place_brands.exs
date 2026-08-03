defmodule Clubeira.Repo.Migrations.CreatePlaceBrands do
  use Ecto.Migration

  def change do
    create table(:place_brands, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :place_id, references(:places, type: :uuid, on_delete: :restrict), null: false
      add :brand_id, references(:brands, type: :uuid, on_delete: :restrict), null: false
      add :role, :text, null: false, default: "primary"
      add :valid_during, :tstzrange, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:place_brands, [:brand_id])

    create constraint(:place_brands, :place_brands_role_check,
             check: "role IN ('primary', 'co_brand')"
           )

    create constraint(:place_brands, :place_brands_valid_during_check,
             check:
               "NOT isempty(valid_during) AND NOT lower_inf(valid_during) AND lower_inc(valid_during) AND NOT upper_inc(valid_during)"
           )

    create constraint(:place_brands, :place_brands_same_pair_no_overlap,
             exclude: "gist (place_id WITH =, brand_id WITH =, valid_during WITH &&)"
           )

    create constraint(:place_brands, :place_brands_one_primary_at_a_time,
             exclude: "gist (place_id WITH =, valid_during WITH &&) WHERE (role = 'primary')"
           )
  end
end
