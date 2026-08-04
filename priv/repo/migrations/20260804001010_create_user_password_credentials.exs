defmodule Clubeira.Repo.Migrations.CreateUserPasswordCredentials do
  use Ecto.Migration

  def change do
    create table(:user_password_credentials, primary_key: false) do
      add :user_id, references(:users, type: :uuid, on_delete: :restrict),
        primary_key: true,
        null: false

      add :password_hash, :text, null: false
      add :password_changed_at, :timestamptz, null: false, default: fragment("now()")

      timestamps(type: :timestamptz, null: false, default: fragment("now()"))
    end

    create constraint(:user_password_credentials, :user_password_credentials_hash_check,
             check: "char_length(password_hash) BETWEEN 20 AND 512"
           )
  end
end
