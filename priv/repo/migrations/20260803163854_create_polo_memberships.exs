defmodule Clubeira.Repo.Migrations.CreatePoloMemberships do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:polo_memberships, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false
      add :user_id, references(:users, type: :uuid, on_delete: :restrict), null: false
      add :valid_during, :tstzrange, null: false
      add :status, :text, null: false, default: "active"

      timestamps(@timestamps_opts)
    end

    create unique_index(:polo_memberships, [:id, :polo_id], name: :polo_memberships_id_polo_uidx)

    create index(:polo_memberships, [:polo_id, :user_id])
    create index(:polo_memberships, [:user_id])

    create constraint(:polo_memberships, :polo_memberships_status_check,
             check: "status IN ('invited', 'active', 'suspended', 'revoked')"
           )

    create constraint(:polo_memberships, :polo_memberships_valid_during_check,
             check:
               "NOT isempty(valid_during) AND NOT lower_inf(valid_during) AND lower_inc(valid_during) AND NOT upper_inc(valid_during)"
           )

    create constraint(:polo_memberships, :polo_memberships_no_overlap,
             exclude: "gist (polo_id WITH =, user_id WITH =, valid_during WITH &&)"
           )
  end
end
