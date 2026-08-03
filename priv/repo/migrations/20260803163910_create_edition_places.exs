defmodule Clubeira.Repo.Migrations.CreateEditionPlaces do
  use Ecto.Migration

  def change do
    create table(:edition_places, primary_key: false) do
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict),
        primary_key: true,
        null: false

      add :edition_id,
          references(:editions,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :edition_places_edition_fkey,
            on_delete: :restrict
          ),
          primary_key: true,
          null: false

      add :polo_place_id,
          references(:polo_places,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :edition_places_polo_place_fkey,
            on_delete: :restrict
          ),
          primary_key: true,
          null: false

      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:edition_places, [:polo_place_id])
  end
end
