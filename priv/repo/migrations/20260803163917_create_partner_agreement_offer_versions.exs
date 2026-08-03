defmodule Clubeira.Repo.Migrations.CreatePartnerAgreementOfferVersions do
  use Ecto.Migration

  def change do
    create table(:partner_agreement_offer_versions, primary_key: false) do
      add :partner_agreement_id,
          references(:partner_agreements, type: :uuid, on_delete: :restrict),
          primary_key: true,
          null: false

      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict),
        primary_key: true,
        null: false

      add :benefit_offer_version_id,
          references(:benefit_offer_versions,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :partner_agreement_offer_versions_offer_fkey,
            on_delete: :restrict
          ),
          primary_key: true,
          null: false

      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:partner_agreement_offer_versions, [:benefit_offer_version_id])
  end
end
