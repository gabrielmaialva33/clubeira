defmodule Clubeira.Repo.Migrations.CreateBrandOwnerships do
  use Ecto.Migration

  def change do
    create table(:brand_ownerships, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :brand_id, references(:brands, type: :uuid, on_delete: :restrict), null: false

      add :organization_id, references(:organizations, type: :uuid, on_delete: :restrict),
        null: false

      add :valid_during, :tstzrange, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:brand_ownerships, [:organization_id])

    create constraint(:brand_ownerships, :brand_ownerships_valid_during_check,
             check:
               "NOT isempty(valid_during) AND NOT lower_inf(valid_during) AND lower_inc(valid_during) AND NOT upper_inc(valid_during)"
           )

    create constraint(:brand_ownerships, :brand_ownerships_no_overlap,
             exclude: "gist (brand_id WITH =, valid_during WITH &&)"
           )
  end
end
