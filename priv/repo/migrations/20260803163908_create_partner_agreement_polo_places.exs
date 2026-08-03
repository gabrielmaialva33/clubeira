defmodule Clubeira.Repo.Migrations.CreatePartnerAgreementPoloPlaces do
  use Ecto.Migration

  def change do
    create table(:partner_agreement_polo_places, primary_key: false) do
      add :partner_agreement_id,
          references(:partner_agreements, type: :uuid, on_delete: :restrict),
          primary_key: true,
          null: false

      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict),
        primary_key: true,
        null: false

      add :polo_place_id,
          references(:polo_places,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :partner_agreement_polo_places_participation_fkey,
            on_delete: :restrict
          ),
          primary_key: true,
          null: false

      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:partner_agreement_polo_places, [:polo_place_id])
  end
end
