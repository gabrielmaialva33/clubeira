defmodule Clubeira.Repo.Migrations.CreateBenefitOfferVersionPlaces do
  use Ecto.Migration

  def change do
    create table(:benefit_offer_version_places, primary_key: false) do
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict),
        primary_key: true,
        null: false

      add :benefit_offer_version_id,
          references(:benefit_offer_versions,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :benefit_offer_version_places_offer_fkey,
            on_delete: :restrict
          ),
          primary_key: true,
          null: false

      add :polo_place_id,
          references(:polo_places,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :benefit_offer_version_places_place_fkey,
            on_delete: :restrict
          ),
          primary_key: true,
          null: false

      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:benefit_offer_version_places, [:polo_place_id])
  end
end
