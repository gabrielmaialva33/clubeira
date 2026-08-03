defmodule Clubeira.Repo.Migrations.CreateEntitlementScopes do
  use Ecto.Migration

  def change do
    create table(:entitlement_scopes, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :benefit_package_version_id,
          references(:benefit_package_versions,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :entitlement_scopes_package_version_fkey,
            on_delete: :restrict
          ),
          null: false

      add :key, :citext, null: false
      add :name, :text, null: false
      add :scope_kind, :text, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(
             :entitlement_scopes,
             [:polo_id, :benefit_package_version_id, :key],
             name: :entitlement_scopes_key_uidx
           )

    create unique_index(:entitlement_scopes, [:id, :polo_id],
             name: :entitlement_scopes_id_polo_uidx
           )

    create unique_index(
             :entitlement_scopes,
             [:id, :polo_id, :benefit_package_version_id],
             name: :entitlement_scopes_package_identity_uidx
           )

    create constraint(:entitlement_scopes, :entitlement_scopes_kind_check,
             check: "scope_kind IN ('place', 'brand', 'organization', 'custom')"
           )
  end
end
