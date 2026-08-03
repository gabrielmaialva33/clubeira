defmodule Clubeira.Repo.Migrations.CreatePartnerAgreementOrganizations do
  use Ecto.Migration

  def change do
    create table(:partner_agreement_organizations, primary_key: false) do
      add :partner_agreement_id,
          references(:partner_agreements, type: :uuid, on_delete: :restrict),
          primary_key: true,
          null: false

      add :organization_id, references(:organizations, type: :uuid, on_delete: :restrict),
        primary_key: true,
        null: false

      add :party_role, :text, null: false, default: "partner"
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:partner_agreement_organizations, [:organization_id])

    create constraint(
             :partner_agreement_organizations,
             :partner_agreement_organizations_role_check,
             check: "party_role IN ('partner', 'operator', 'guarantor')"
           )
  end
end
