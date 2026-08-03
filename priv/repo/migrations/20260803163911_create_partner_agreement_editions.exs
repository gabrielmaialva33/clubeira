defmodule Clubeira.Repo.Migrations.CreatePartnerAgreementEditions do
  use Ecto.Migration

  def change do
    create table(:partner_agreement_editions, primary_key: false) do
      add :partner_agreement_id,
          references(:partner_agreements, type: :uuid, on_delete: :restrict),
          primary_key: true,
          null: false

      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict),
        primary_key: true,
        null: false

      add :edition_id,
          references(:editions,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :partner_agreement_editions_edition_fkey,
            on_delete: :restrict
          ),
          primary_key: true,
          null: false

      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:partner_agreement_editions, [:edition_id])
  end
end
