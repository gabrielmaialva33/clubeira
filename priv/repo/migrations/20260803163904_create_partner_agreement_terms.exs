defmodule Clubeira.Repo.Migrations.CreatePartnerAgreementTerms do
  use Ecto.Migration

  def change do
    create table(:partner_agreement_terms, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")

      add :partner_agreement_id,
          references(:partner_agreements, type: :uuid, on_delete: :restrict),
          null: false

      add :version, :integer, null: false
      add :effective_during, :tstzrange, null: false
      add :settlement_model, :text, null: false, default: "none"
      add :redemption_sla_seconds, :integer, null: false, default: 30
      add :published_at, :timestamptz, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:partner_agreement_terms, [:partner_agreement_id, :version])

    create constraint(:partner_agreement_terms, :partner_agreement_terms_version_check,
             check: "version > 0"
           )

    create constraint(:partner_agreement_terms, :partner_agreement_terms_model_check,
             check: "settlement_model IN ('none', 'fixed', 'revenue_share')"
           )

    create constraint(:partner_agreement_terms, :partner_agreement_terms_sla_check,
             check: "redemption_sla_seconds > 0"
           )

    create constraint(:partner_agreement_terms, :partner_agreement_terms_effective_check,
             check:
               "NOT isempty(effective_during) AND NOT lower_inf(effective_during) AND lower_inc(effective_during) AND NOT upper_inc(effective_during)"
           )

    create constraint(:partner_agreement_terms, :partner_agreement_terms_no_overlap,
             exclude: "gist (partner_agreement_id WITH =, effective_during WITH &&)"
           )
  end
end
