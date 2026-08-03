defmodule Clubeira.Repo.Migrations.CreatePlaceOperators do
  use Ecto.Migration

  def change do
    create table(:place_operators, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :place_id, references(:places, type: :uuid, on_delete: :restrict), null: false

      add :organization_id, references(:organizations, type: :uuid, on_delete: :restrict),
        null: false

      add :role, :text, null: false, default: "operator"
      add :valid_during, :tstzrange, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:place_operators, [:organization_id])

    create constraint(:place_operators, :place_operators_role_check,
             check: "role IN ('operator', 'owner', 'manager')"
           )

    create constraint(:place_operators, :place_operators_valid_during_check,
             check:
               "NOT isempty(valid_during) AND NOT lower_inf(valid_during) AND lower_inc(valid_during) AND NOT upper_inc(valid_during)"
           )

    create constraint(:place_operators, :place_operators_same_pair_no_overlap,
             exclude: "gist (place_id WITH =, organization_id WITH =, valid_during WITH &&)"
           )

    create constraint(:place_operators, :place_operators_one_operator_at_a_time,
             exclude: "gist (place_id WITH =, valid_during WITH &&) WHERE (role = 'operator')"
           )
  end
end
