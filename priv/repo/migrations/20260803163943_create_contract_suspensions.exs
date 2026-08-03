defmodule Clubeira.Repo.Migrations.CreateContractSuspensions do
  use Ecto.Migration

  def change do
    create table(:contract_suspensions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :access_contract_id,
          references(:access_contracts,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :contract_suspensions_contract_fkey,
            on_delete: :restrict
          ),
          null: false

      add :source_contract_event_id,
          references(:contract_events,
            type: :uuid,
            with: [polo_id: :polo_id, access_contract_id: :access_contract_id],
            name: :contract_suspensions_source_event_fkey,
            on_delete: :restrict
          ),
          null: false

      add :reason, :text, null: false
      add :suspended_during, :tstzrange, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:contract_suspensions, [:id, :polo_id],
             name: :contract_suspensions_id_polo_uidx
           )

    create index(:contract_suspensions, [:polo_id, :access_contract_id])

    create constraint(:contract_suspensions, :contract_suspensions_range_check,
             check:
               "NOT isempty(suspended_during) AND NOT lower_inf(suspended_during) AND lower_inc(suspended_during) AND NOT upper_inc(suspended_during)"
           )

    create constraint(:contract_suspensions, :contract_suspensions_no_overlap,
             exclude: "gist (access_contract_id WITH =, suspended_during WITH &&)"
           )
  end
end
