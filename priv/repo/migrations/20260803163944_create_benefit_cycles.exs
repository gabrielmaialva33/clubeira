defmodule Clubeira.Repo.Migrations.CreateBenefitCycles do
  use Ecto.Migration

  def change do
    create table(:benefit_cycles, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :access_contract_id,
          references(:access_contracts,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :benefit_cycles_contract_fkey,
            on_delete: :restrict
          ),
          null: false

      add :benefit_package_version_id,
          references(:benefit_package_versions,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :benefit_cycles_package_version_fkey,
            on_delete: :restrict
          ),
          null: false

      add :offering_package_assignment_id,
          references(:product_offering_package_assignments,
            type: :uuid,
            with: [polo_id: :polo_id, benefit_package_version_id: :benefit_package_version_id],
            name: :benefit_cycles_package_assignment_fkey,
            on_delete: :restrict
          ),
          null: false

      add :polo_policy_version_id,
          references(:polo_policy_versions,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :benefit_cycles_polo_policy_fkey,
            on_delete: :restrict
          ),
          null: false

      add :sequence, :integer, null: false
      add :benefits_during, :tstzrange, null: false
      add :status, :text, null: false, default: "planned"
      add :delinquency_grace_until, :timestamptz
      add :activated_at, :timestamptz
      add :closed_at, :timestamptz
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:benefit_cycles, [:id, :polo_id], name: :benefit_cycles_id_polo_uidx)

    create unique_index(:benefit_cycles, [:id, :polo_id, :access_contract_id],
             name: :benefit_cycles_contract_identity_uidx
           )

    create unique_index(:benefit_cycles, [:polo_id, :access_contract_id, :sequence],
             name: :benefit_cycles_sequence_uidx
           )

    create index(:benefit_cycles, [:polo_id, :status, :benefits_during])

    create constraint(:benefit_cycles, :benefit_cycles_sequence_check, check: "sequence > 0")

    create constraint(:benefit_cycles, :benefit_cycles_status_check,
             check: "status IN ('planned', 'active', 'closed', 'cancelled')"
           )

    create constraint(:benefit_cycles, :benefit_cycles_range_check,
             check:
               "NOT isempty(benefits_during) AND NOT lower_inf(benefits_during) AND NOT upper_inf(benefits_during) AND lower_inc(benefits_during) AND NOT upper_inc(benefits_during)"
           )

    create constraint(:benefit_cycles, :benefit_cycles_no_overlap,
             exclude: "gist (access_contract_id WITH =, benefits_during WITH &&)"
           )
  end
end
