defmodule Clubeira.Repo.Migrations.CreatePoloRoutes do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def up do
    create table(:polo_routes, primary_key: false) do
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict),
        primary_key: true,
        null: false

      add :slug, :citext, null: false

      timestamps(@timestamps_opts)
    end

    create unique_index(:polo_routes, [:slug])

    create constraint(:polo_routes, :polo_routes_slug_check,
             check:
               "slug::text = lower(slug::text) AND char_length(slug::text) BETWEEN 2 AND 80 AND slug::text ~ '^[a-z0-9]+(-[a-z0-9]+)*$'"
           )

    execute("ALTER TABLE polo_routes ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE polo_routes FORCE ROW LEVEL SECURITY")

    execute("""
    CREATE POLICY polo_routes_public_read ON polo_routes
    FOR SELECT
    USING (true)
    """)

    execute("""
    CREATE POLICY polo_routes_scoped_write ON polo_routes
    FOR ALL
    USING (
      polo_id = NULLIF(current_setting('app.current_polo_id', true), '')::uuid
    )
    WITH CHECK (
      polo_id = NULLIF(current_setting('app.current_polo_id', true), '')::uuid
    )
    """)
  end

  def down do
    drop table(:polo_routes)
  end
end
