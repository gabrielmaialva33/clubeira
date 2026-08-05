defmodule Clubeira.Repo.Migrations.CreateValidationCredentials do
  use Ecto.Migration

  def change do
    create table(:validation_credentials, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :validation_point_id,
          references(:validation_points,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :validation_credentials_point_fkey,
            on_delete: :restrict
          ),
          null: false

      add :version, :integer, null: false
      add :kind, :text, null: false
      add :public_key, :binary
      add :secret_hash, :binary
      add :valid_during, :tstzrange, null: false
      add :status, :text, null: false, default: "active"
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:validation_credentials, [:polo_id, :validation_point_id, :version],
             name: :validation_credentials_version_uidx
           )

    create index(:validation_credentials, [:validation_point_id])

    create unique_index(:validation_credentials, [:secret_hash],
             name: :validation_credentials_secret_hash_uidx,
             where: "secret_hash IS NOT NULL"
           )

    create constraint(:validation_credentials, :validation_credentials_version_check,
             check: "version > 0"
           )

    create constraint(:validation_credentials, :validation_credentials_kind_check,
             check:
               "kind IN ('static_qr', 'rotating_qr', 'nfc', 'manual_code', 'public_key', 'api_key')"
           )

    create constraint(:validation_credentials, :validation_credentials_material_check,
             check: "(public_key IS NULL) <> (secret_hash IS NULL)"
           )

    create constraint(:validation_credentials, :validation_credentials_status_check,
             check: "status IN ('active', 'revoked', 'expired')"
           )

    create constraint(:validation_credentials, :validation_credentials_range_check,
             check:
               "NOT isempty(valid_during) AND NOT lower_inf(valid_during) AND lower_inc(valid_during) AND NOT upper_inc(valid_during)"
           )

    create constraint(:validation_credentials, :validation_credentials_no_overlap,
             exclude: "gist (validation_point_id WITH =, kind WITH =, valid_during WITH &&)"
           )
  end
end
