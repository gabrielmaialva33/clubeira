defmodule Clubeira.Repo.Migrations.CreateCycleEntitlementSubjects do
  use Ecto.Migration

  def change do
    create table(:cycle_entitlement_subjects, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false
      add :access_contract_id, :uuid, null: false

      add :benefit_cycle_id,
          references(:benefit_cycles,
            type: :uuid,
            with: [polo_id: :polo_id, access_contract_id: :access_contract_id],
            name: :cycle_entitlement_subjects_cycle_fkey,
            on_delete: :restrict
          ),
          null: false

      add :contract_beneficiary_id,
          references(:contract_beneficiaries,
            type: :uuid,
            with: [polo_id: :polo_id, access_contract_id: :access_contract_id],
            match: :simple,
            name: :cycle_entitlement_subjects_beneficiary_fkey,
            on_delete: :restrict
          )

      add :subject_kind, :text, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:cycle_entitlement_subjects, [:id, :polo_id],
             name: :cycle_entitlement_subjects_id_polo_uidx
           )

    create unique_index(
             :cycle_entitlement_subjects,
             [:polo_id, :benefit_cycle_id, :contract_beneficiary_id],
             nulls_distinct: false,
             name: :cycle_entitlement_subjects_identity_uidx
           )

    create constraint(:cycle_entitlement_subjects, :cycle_entitlement_subjects_kind_check,
             check:
               "(subject_kind = 'contract' AND contract_beneficiary_id IS NULL) OR (subject_kind = 'beneficiary' AND contract_beneficiary_id IS NOT NULL)"
           )
  end
end
