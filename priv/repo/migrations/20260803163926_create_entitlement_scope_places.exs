defmodule Clubeira.Repo.Migrations.CreateEntitlementScopePlaces do
  use Ecto.Migration

  def change do
    create table(:entitlement_scope_places, primary_key: false) do
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict),
        primary_key: true,
        null: false

      add :entitlement_scope_id,
          references(:entitlement_scopes,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :entitlement_scope_places_scope_fkey,
            on_delete: :restrict
          ),
          primary_key: true,
          null: false

      add :polo_place_id,
          references(:polo_places,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :entitlement_scope_places_place_fkey,
            on_delete: :restrict
          ),
          primary_key: true,
          null: false

      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:entitlement_scope_places, [:polo_place_id])
  end
end
