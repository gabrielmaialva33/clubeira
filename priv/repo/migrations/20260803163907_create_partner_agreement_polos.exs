defmodule Clubeira.Repo.Migrations.CreatePartnerAgreementPolos do
  use Ecto.Migration

  def change do
    create table(:partner_agreement_polos, primary_key: false) do
      add :partner_agreement_id,
          references(:partner_agreements, type: :uuid, on_delete: :restrict),
          primary_key: true,
          null: false

      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict),
        primary_key: true,
        null: false

      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:partner_agreement_polos, [:polo_id])
  end
end
