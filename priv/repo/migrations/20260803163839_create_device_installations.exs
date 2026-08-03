defmodule Clubeira.Repo.Migrations.CreateDeviceInstallations do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:device_installations, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :installation_token_hash, :binary, null: false
      add :platform, :text, null: false
      add :status, :text, null: false, default: "active"
      add :first_seen_at, :timestamptz, null: false, default: fragment("now()")
      add :last_seen_at, :timestamptz, null: false, default: fragment("now()")

      timestamps(@timestamps_opts)
    end

    create unique_index(:device_installations, [:installation_token_hash])

    create constraint(:device_installations, :device_installations_platform_check,
             check: "platform IN ('android', 'ios', 'web')"
           )

    create constraint(:device_installations, :device_installations_status_check,
             check: "status IN ('active', 'blocked', 'retired')"
           )
  end
end
