defmodule Clubeira.Repo.Migrations.CreateOrganizationIdentifiers do
  use Ecto.Migration

  def change do
    create table(:organization_identifiers, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")

      add :organization_id, references(:organizations, type: :uuid, on_delete: :restrict),
        null: false

      add :kind, :text, null: false
      add :ciphertext, :binary, null: false
      add :lookup_token, :binary, null: false
      add :key_version, :smallint, null: false
      add :verified_at, :timestamptz
      add :revoked_at, :timestamptz
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:organization_identifiers, [:organization_id])

    create unique_index(:organization_identifiers, [:kind, :lookup_token],
             where: "revoked_at IS NULL",
             name: :organization_identifiers_active_lookup_uidx
           )

    create constraint(:organization_identifiers, :organization_identifiers_kind_check,
             check: "kind IN ('cnpj', 'tax_id', 'registration', 'other')"
           )

    create constraint(:organization_identifiers, :organization_identifiers_key_version_check,
             check: "key_version > 0"
           )
  end
end
