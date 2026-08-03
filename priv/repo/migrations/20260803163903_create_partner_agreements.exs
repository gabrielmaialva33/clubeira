defmodule Clubeira.Repo.Migrations.CreatePartnerAgreements do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:partner_agreements, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :agreement_number, :citext, null: false
      add :name, :text, null: false
      add :valid_during, :tstzrange, null: false
      add :status, :text, null: false, default: "draft"
      add :signed_at, :timestamptz
      add :terminated_at, :timestamptz

      timestamps(@timestamps_opts)
    end

    create unique_index(:partner_agreements, [:agreement_number])

    create constraint(:partner_agreements, :partner_agreements_status_check,
             check: "status IN ('draft', 'active', 'suspended', 'terminated', 'expired')"
           )

    create constraint(:partner_agreements, :partner_agreements_valid_during_check,
             check:
               "NOT isempty(valid_during) AND NOT lower_inf(valid_during) AND lower_inc(valid_during) AND NOT upper_inc(valid_during)"
           )
  end
end
