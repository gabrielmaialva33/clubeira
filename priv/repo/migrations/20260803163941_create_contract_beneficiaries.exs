defmodule Clubeira.Repo.Migrations.CreateContractBeneficiaries do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:contract_beneficiaries, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :access_contract_id,
          references(:access_contracts,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :contract_beneficiaries_contract_fkey,
            on_delete: :restrict
          ),
          null: false

      add :person_id, references(:persons, type: :uuid, on_delete: :restrict), null: false
      add :relationship, :text, null: false, default: "holder"
      add :valid_during, :tstzrange, null: false
      add :status, :text, null: false, default: "active"

      timestamps(@timestamps_opts)
    end

    create unique_index(:contract_beneficiaries, [:id, :polo_id],
             name: :contract_beneficiaries_id_polo_uidx
           )

    create unique_index(:contract_beneficiaries, [:id, :polo_id, :access_contract_id],
             name: :contract_beneficiaries_contract_identity_uidx
           )

    create index(:contract_beneficiaries, [:polo_id, :access_contract_id])
    create index(:contract_beneficiaries, [:person_id])

    create constraint(:contract_beneficiaries, :contract_beneficiaries_relationship_check,
             check: "relationship IN ('holder', 'dependent', 'guest')"
           )

    create constraint(:contract_beneficiaries, :contract_beneficiaries_status_check,
             check: "status IN ('active', 'suspended', 'removed')"
           )

    create constraint(:contract_beneficiaries, :contract_beneficiaries_valid_during_check,
             check:
               "NOT isempty(valid_during) AND NOT lower_inf(valid_during) AND lower_inc(valid_during) AND NOT upper_inc(valid_during)"
           )

    create constraint(:contract_beneficiaries, :contract_beneficiaries_no_overlap,
             exclude: "gist (access_contract_id WITH =, person_id WITH =, valid_during WITH &&)"
           )
  end
end
