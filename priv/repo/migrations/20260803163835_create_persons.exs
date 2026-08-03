defmodule Clubeira.Repo.Migrations.CreatePersons do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:persons, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :display_name, :text, null: false
      add :birth_date, :date
      add :status, :text, null: false, default: "active"
      add :anonymized_at, :timestamptz

      timestamps(@timestamps_opts)
    end

    create constraint(:persons, :persons_status_check,
             check: "status IN ('active', 'restricted', 'anonymized', 'deceased')"
           )
  end
end
