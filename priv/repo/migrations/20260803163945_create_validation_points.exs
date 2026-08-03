defmodule Clubeira.Repo.Migrations.CreateValidationPoints do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:validation_points, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :polo_place_id,
          references(:polo_places,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :validation_points_polo_place_fkey,
            on_delete: :restrict
          ),
          null: false

      add :name, :text, null: false
      add :kind, :text, null: false
      add :status, :text, null: false, default: "active"

      timestamps(@timestamps_opts)
    end

    create unique_index(:validation_points, [:id, :polo_id],
             name: :validation_points_id_polo_uidx
           )

    create unique_index(:validation_points, [:id, :polo_id, :polo_place_id],
             name: :validation_points_place_identity_uidx
           )

    create index(:validation_points, [:polo_id, :polo_place_id])

    create constraint(:validation_points, :validation_points_kind_check,
             check: "kind IN ('merchant_app', 'qr_placard', 'terminal', 'api')"
           )

    create constraint(:validation_points, :validation_points_status_check,
             check: "status IN ('active', 'suspended', 'retired')"
           )
  end
end
