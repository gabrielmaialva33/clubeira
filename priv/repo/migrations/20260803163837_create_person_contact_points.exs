defmodule Clubeira.Repo.Migrations.CreatePersonContactPoints do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:person_contact_points, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :person_id, references(:persons, type: :uuid, on_delete: :restrict), null: false
      add :kind, :text, null: false
      add :ciphertext, :binary, null: false
      add :lookup_token, :binary, null: false
      add :key_version, :smallint, null: false
      add :is_primary, :boolean, null: false, default: false
      add :verified_at, :timestamptz
      add :revoked_at, :timestamptz

      timestamps(@timestamps_opts)
    end

    create index(:person_contact_points, [:person_id])

    create unique_index(:person_contact_points, [:kind, :lookup_token],
             where: "revoked_at IS NULL",
             name: :person_contact_points_active_lookup_uidx
           )

    create unique_index(:person_contact_points, [:person_id, :kind],
             where: "is_primary AND revoked_at IS NULL",
             name: :person_contact_points_primary_uidx
           )

    create constraint(:person_contact_points, :person_contact_points_kind_check,
             check: "kind IN ('email', 'phone')"
           )

    create constraint(:person_contact_points, :person_contact_points_key_version_check,
             check: "key_version > 0"
           )
  end
end
