defmodule Clubeira.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:users, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :email, :citext, null: false
      add :status, :text, null: false, default: "pending"
      add :authenticated_at, :timestamptz
      add :email_verified_at, :timestamptz
      add :disabled_at, :timestamptz

      timestamps(@timestamps_opts)
    end

    create unique_index(:users, [:email])

    create constraint(:users, :users_status_check,
             check: "status IN ('pending', 'active', 'blocked', 'closed')"
           )
  end
end
