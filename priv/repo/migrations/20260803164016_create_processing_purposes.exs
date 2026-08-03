defmodule Clubeira.Repo.Migrations.CreateProcessingPurposes do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:processing_purposes, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :code, :citext, null: false
      add :name, :text, null: false
      add :legal_basis, :text, null: false
      add :status, :text, null: false, default: "active"

      timestamps(@timestamps_opts)
    end

    create unique_index(:processing_purposes, [:code])

    create constraint(:processing_purposes, :processing_purposes_legal_basis_check,
             check:
               "legal_basis IN ('consent', 'contract', 'legal_obligation', 'legitimate_interest', 'credit_protection', 'fraud_prevention')"
           )

    create constraint(:processing_purposes, :processing_purposes_status_check,
             check: "status IN ('active', 'retired')"
           )
  end
end
