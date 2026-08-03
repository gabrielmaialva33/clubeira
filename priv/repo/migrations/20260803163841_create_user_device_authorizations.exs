defmodule Clubeira.Repo.Migrations.CreateUserDeviceAuthorizations do
  use Ecto.Migration

  def change do
    create table(:user_device_authorizations, primary_key: false) do
      add :user_id, references(:users, type: :uuid, on_delete: :restrict),
        primary_key: true,
        null: false

      add :device_installation_id,
          references(:device_installations, type: :uuid, on_delete: :restrict),
          primary_key: true,
          null: false

      add :status, :text, null: false, default: "active"
      add :authorized_at, :timestamptz, null: false, default: fragment("now()")
      add :revoked_at, :timestamptz
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:user_device_authorizations, [:device_installation_id])

    create constraint(:user_device_authorizations, :user_device_authorizations_status_check,
             check: "status IN ('active', 'revoked')"
           )
  end
end
