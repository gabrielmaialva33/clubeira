defmodule Clubeira.Repo.Migrations.CreateOrganizationMembershipRoles do
  use Ecto.Migration

  def change do
    create table(:organization_membership_roles, primary_key: false) do
      add :organization_id, references(:organizations, type: :uuid, on_delete: :restrict),
        primary_key: true,
        null: false

      add :organization_membership_id,
          references(:organization_memberships,
            type: :uuid,
            with: [organization_id: :organization_id],
            name: :organization_membership_roles_membership_fkey,
            on_delete: :restrict
          ),
          primary_key: true,
          null: false

      add :organization_role_id,
          references(:organization_roles,
            type: :uuid,
            with: [organization_id: :organization_id],
            name: :organization_membership_roles_role_fkey,
            on_delete: :restrict
          ),
          primary_key: true,
          null: false

      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:organization_membership_roles, [:organization_role_id])
  end
end
