defmodule Clubeira.Repo.Migrations.CreatePoloMembershipRoles do
  use Ecto.Migration

  def change do
    create table(:polo_membership_roles, primary_key: false) do
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict),
        primary_key: true,
        null: false

      add :polo_membership_id,
          references(:polo_memberships,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :polo_membership_roles_membership_fkey,
            on_delete: :restrict
          ),
          primary_key: true,
          null: false

      add :polo_role_id,
          references(:polo_roles,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :polo_membership_roles_role_fkey,
            on_delete: :restrict
          ),
          primary_key: true,
          null: false

      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:polo_membership_roles, [:polo_role_id])
  end
end
