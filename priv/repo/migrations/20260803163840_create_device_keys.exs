defmodule Clubeira.Repo.Migrations.CreateDeviceKeys do
  use Ecto.Migration

  def change do
    create table(:device_keys, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")

      add :device_installation_id,
          references(:device_installations, type: :uuid, on_delete: :restrict),
          null: false

      add :key_thumbprint, :binary, null: false
      add :public_key, :binary, null: false
      add :attestation_kind, :text, null: false, default: "none"
      add :attestation_status, :text, null: false, default: "unverified"
      add :valid_during, :tstzrange, null: false
      add :revoked_at, :timestamptz
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:device_keys, [:key_thumbprint])
    create index(:device_keys, [:device_installation_id])

    create constraint(:device_keys, :device_keys_valid_during_check,
             check:
               "NOT isempty(valid_during) AND NOT lower_inf(valid_during) AND lower_inc(valid_during) AND NOT upper_inc(valid_during)"
           )

    create constraint(:device_keys, :device_keys_no_overlap,
             exclude: "gist (device_installation_id WITH =, valid_during WITH &&)"
           )

    create constraint(:device_keys, :device_keys_attestation_kind_check,
             check:
               "attestation_kind IN ('none', 'apple_app_attest', 'play_integrity', 'webauthn')"
           )

    create constraint(:device_keys, :device_keys_attestation_status_check,
             check: "attestation_status IN ('unverified', 'verified', 'failed')"
           )
  end
end
