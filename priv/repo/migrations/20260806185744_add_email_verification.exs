defmodule Clubeira.Repo.Migrations.AddEmailVerification do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :email_verified_at, :timestamptz
    end

    create table(:user_email_verification_tokens, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :user_id, references(:users, type: :uuid, on_delete: :restrict), null: false
      add :token_hash, :binary, null: false
      add :expires_at, :timestamptz, null: false
      add :consumed_at, :timestamptz
      add :revoked_at, :timestamptz
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:user_email_verification_tokens, [:token_hash])

    create unique_index(:user_email_verification_tokens, [:user_id],
             where: "consumed_at IS NULL AND revoked_at IS NULL",
             name: :user_email_verification_tokens_one_active_per_user_idx
           )

    create index(:user_email_verification_tokens, [:expires_at],
             name: :user_email_verification_tokens_expires_at_idx
           )

    create constraint(
             :user_email_verification_tokens,
             :user_email_verification_tokens_hash_check,
             check: "octet_length(token_hash) = 32"
           )

    create constraint(
             :user_email_verification_tokens,
             :user_email_verification_tokens_dates_check,
             check:
               "expires_at > inserted_at AND " <>
                 "(consumed_at IS NULL OR consumed_at >= inserted_at) AND " <>
                 "(revoked_at IS NULL OR revoked_at >= inserted_at)"
           )

    create constraint(
             :user_email_verification_tokens,
             :user_email_verification_tokens_terminal_state_check,
             check: "consumed_at IS NULL OR revoked_at IS NULL"
           )
  end
end
