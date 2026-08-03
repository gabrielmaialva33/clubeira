defmodule Clubeira.Repo.Migrations.CreateAccessProducts do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:access_products, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false
      add :code, :citext, null: false
      add :name, :text, null: false
      add :status, :text, null: false, default: "draft"

      timestamps(@timestamps_opts)
    end

    create unique_index(:access_products, [:polo_id, :code])
    create unique_index(:access_products, [:id, :polo_id], name: :access_products_id_polo_uidx)

    create constraint(:access_products, :access_products_status_check,
             check: "status IN ('draft', 'active', 'retired')"
           )
  end
end
