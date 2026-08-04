defmodule Clubeira.Repo.Migrations.CreateUserSessions do
  use Ecto.Migration

  def change do
    create table(:user_sessions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :user_id, references(:users, type: :uuid, on_delete: :restrict), null: false
      add :token_hash, :binary, null: false
      add :expires_at, :timestamptz, null: false
      add :revoked_at, :timestamptz
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:user_sessions, [:token_hash])

    create index(:user_sessions, [:user_id, :expires_at],
             where: "revoked_at IS NULL",
             name: :user_sessions_active_lookup_idx
           )

    create index(:user_sessions, [:expires_at], name: :user_sessions_expires_at_idx)

    create index(:user_sessions, [:revoked_at],
             where: "revoked_at IS NOT NULL",
             name: :user_sessions_revoked_at_idx
           )

    create constraint(:user_sessions, :user_sessions_token_hash_check,
             check: "octet_length(token_hash) = 32"
           )

    create constraint(:user_sessions, :user_sessions_dates_check,
             check:
               "expires_at > inserted_at AND (revoked_at IS NULL OR revoked_at >= inserted_at)"
           )
  end
end
