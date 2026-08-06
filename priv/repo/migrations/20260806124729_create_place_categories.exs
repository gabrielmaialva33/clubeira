defmodule Clubeira.Repo.Migrations.CreatePlaceCategories do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:place_categories, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :key, :citext, null: false
      add :name, :text, null: false
      add :status, :text, null: false, default: "active"
      add :display_order, :smallint, null: false, default: 0

      timestamps(@timestamps_opts)
    end

    create unique_index(:place_categories, [:key])
    create index(:place_categories, [:status, :display_order, :key])

    create constraint(:place_categories, :place_categories_key_check,
             check:
               "key::text = lower(key::text) AND char_length(key::text) BETWEEN 2 AND 80 AND key::text ~ '^[a-z0-9]+(-[a-z0-9]+)*$'"
           )

    create constraint(:place_categories, :place_categories_name_check,
             check: "char_length(name) BETWEEN 2 AND 120"
           )

    create constraint(:place_categories, :place_categories_status_check,
             check: "status IN ('active', 'retired')"
           )

    create constraint(:place_categories, :place_categories_display_order_check,
             check: "display_order >= 0"
           )
  end
end
