defmodule Clubeira.Repo.Migrations.CreateRedemptionEvents do
  use Ecto.Migration

  def change do
    create table(:redemption_events, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :redemption_id,
          references(:redemptions,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :redemption_events_redemption_fkey,
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

    create unique_index(:redemption_events, [:polo_id, :redemption_id, :sequence],
             name: :redemption_events_sequence_uidx
           )

    create constraint(:redemption_events, :redemption_events_sequence_check,
             check: "sequence > 0"
           )
  end
end
