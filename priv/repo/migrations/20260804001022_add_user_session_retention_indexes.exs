defmodule Clubeira.Repo.Migrations.AddUserSessionRetentionIndexes do
  use Ecto.Migration

  def change do
    create index(:user_sessions, [:expires_at], name: :user_sessions_expires_at_idx)

    create index(:user_sessions, [:revoked_at],
             where: "revoked_at IS NOT NULL",
             name: :user_sessions_revoked_at_idx
           )
  end
end
