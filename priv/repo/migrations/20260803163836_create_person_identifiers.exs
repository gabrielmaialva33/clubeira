defmodule Clubeira.Repo.Migrations.CreatePersonIdentifiers do
  use Ecto.Migration

  def change do
    create table(:person_identifiers, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :person_id, references(:persons, type: :uuid, on_delete: :restrict), null: false
      add :kind, :text, null: false
      add :ciphertext, :binary, null: false
      add :lookup_token, :binary, null: false
      add :key_version, :smallint, null: false
      add :verified_at, :timestamptz
      add :revoked_at, :timestamptz
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:person_identifiers, [:person_id])

    create unique_index(:person_identifiers, [:kind, :lookup_token],
             where: "revoked_at IS NULL",
             name: :person_identifiers_active_lookup_uidx
           )

    create constraint(:person_identifiers, :person_identifiers_kind_check,
             check: "kind IN ('cpf', 'passport', 'national_id', 'other')"
           )

    create constraint(:person_identifiers, :person_identifiers_key_version_check,
             check: "key_version > 0"
           )
  end
end
