defmodule Clubeira.Repo.Migrations.CreateDomainEvents do
  use Ecto.Migration

  def change do
    create table(:domain_events, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict)
      add :aggregate_type, :text, null: false
      add :aggregate_id, :uuid, null: false
      add :aggregate_version, :integer, null: false
      add :event_type, :text, null: false
      add :payload, :map, null: false
      add :metadata, :map, null: false, default: %{}
      add :occurred_at, :timestamptz, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(
             :domain_events,
             [:polo_id, :aggregate_type, :aggregate_id, :aggregate_version],
             nulls_distinct: false,
             name: :domain_events_aggregate_version_uidx
           )

    create index(:domain_events, [:event_type, :occurred_at])

    create constraint(:domain_events, :domain_events_version_check,
             check: "aggregate_version > 0"
           )
  end
end
