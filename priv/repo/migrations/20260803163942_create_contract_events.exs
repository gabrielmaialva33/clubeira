defmodule Clubeira.Repo.Migrations.CreateContractEvents do
  use Ecto.Migration

  def change do
    create table(:contract_events, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :access_contract_id,
          references(:access_contracts,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :contract_events_contract_fkey,
            on_delete: :restrict
          ),
          null: false

      add :sequence, :integer, null: false
      add :event_type, :text, null: false
      add :actor_user_id, references(:users, type: :uuid, on_delete: :restrict)
      add :payload, :map, null: false, default: %{}
      add :occurred_at, :timestamptz, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:contract_events, [:id, :polo_id, :access_contract_id],
             name: :contract_events_contract_identity_uidx
           )

    create unique_index(:contract_events, [:polo_id, :access_contract_id, :sequence],
             name: :contract_events_sequence_uidx
           )

    create index(:contract_events, [:actor_user_id])

    create constraint(:contract_events, :contract_events_sequence_check, check: "sequence > 0")
  end
end
