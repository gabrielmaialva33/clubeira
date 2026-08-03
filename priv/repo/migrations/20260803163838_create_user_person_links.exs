defmodule Clubeira.Repo.Migrations.CreateUserPersonLinks do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:user_person_links, primary_key: false) do
      add :user_id, references(:users, type: :uuid, on_delete: :restrict),
        primary_key: true,
        null: false

      add :person_id, references(:persons, type: :uuid, on_delete: :restrict),
        primary_key: true,
        null: false

      add :relationship, :text, null: false
      add :status, :text, null: false, default: "active"

      timestamps(@timestamps_opts)
    end

    create index(:user_person_links, [:person_id])

    create unique_index(:user_person_links, [:person_id],
             where: "relationship = 'self' AND status = 'active'",
             name: :user_person_links_active_self_uidx
           )

    create constraint(:user_person_links, :user_person_links_relationship_check,
             check: "relationship IN ('self', 'guardian', 'delegate')"
           )

    create constraint(:user_person_links, :user_person_links_status_check,
             check: "status IN ('active', 'revoked')"
           )
  end
end
