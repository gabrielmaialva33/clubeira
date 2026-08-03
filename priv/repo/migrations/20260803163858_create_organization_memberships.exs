defmodule Clubeira.Repo.Migrations.CreateOrganizationMemberships do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:organization_memberships, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")

      add :organization_id, references(:organizations, type: :uuid, on_delete: :restrict),
        null: false

      add :user_id, references(:users, type: :uuid, on_delete: :restrict), null: false
      add :valid_during, :tstzrange, null: false
      add :status, :text, null: false, default: "active"

      timestamps(@timestamps_opts)
    end

    create unique_index(:organization_memberships, [:id, :organization_id],
             name: :organization_memberships_id_org_uidx
           )

    create unique_index(:organization_memberships, [:id, :organization_id, :user_id],
             name: :organization_memberships_identity_uidx
           )

    create index(:organization_memberships, [:organization_id, :user_id])
    create index(:organization_memberships, [:user_id])

    create constraint(:organization_memberships, :organization_memberships_status_check,
             check: "status IN ('invited', 'active', 'suspended', 'revoked')"
           )

    create constraint(:organization_memberships, :organization_memberships_valid_during_check,
             check:
               "NOT isempty(valid_during) AND NOT lower_inf(valid_during) AND lower_inc(valid_during) AND NOT upper_inc(valid_during)"
           )

    create constraint(:organization_memberships, :organization_memberships_no_overlap,
             exclude: "gist (organization_id WITH =, user_id WITH =, valid_during WITH &&)"
           )
  end
end
