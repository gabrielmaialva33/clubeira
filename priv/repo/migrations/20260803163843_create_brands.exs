defmodule Clubeira.Repo.Migrations.CreateBrands do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:brands, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :slug, :citext, null: false
      add :name, :text, null: false
      add :status, :text, null: false, default: "active"

      timestamps(@timestamps_opts)
    end

    create unique_index(:brands, [:slug])

    create constraint(:brands, :brands_status_check,
             check: "status IN ('active', 'inactive', 'retired')"
           )
  end
end
