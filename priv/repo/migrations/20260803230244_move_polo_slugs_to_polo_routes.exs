defmodule Clubeira.Repo.Migrations.MovePoloSlugsToPoloRoutes do
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

    execute("ALTER TABLE polos NO FORCE ROW LEVEL SECURITY")

    execute("""
    DO $$
    DECLARE
      invalid_count bigint;
      invalid_examples text;
    BEGIN
      SELECT
        COALESCE(max(total_count), 0),
        string_agg(quote_literal(slug), ', ' ORDER BY slug)
      INTO invalid_count, invalid_examples
      FROM (
        SELECT slug::text AS slug, count(*) OVER () AS total_count
        FROM polos
        WHERE slug::text <> lower(slug::text)
           OR char_length(slug::text) NOT BETWEEN 2 AND 80
           OR slug::text !~ '^[a-z0-9]+(-[a-z0-9]+)*$'
        ORDER BY slug::text
        LIMIT 10
      ) AS invalid;

      IF invalid_count > 0 THEN
        RAISE EXCEPTION
          USING
            MESSAGE = format(
              'cannot migrate %s invalid legacy polo slug(s); examples: %s',
              invalid_count,
              invalid_examples
            ),
            HINT = 'rename each slug to lowercase kebab-case before retrying the migration';
      END IF;
    END
    $$
    """)

    execute("""
    INSERT INTO polo_routes (polo_id, slug, inserted_at, updated_at)
    SELECT id, slug, inserted_at, updated_at
    FROM polos
    """)

    execute("ALTER TABLE polos FORCE ROW LEVEL SECURITY")

    alter table(:polos) do
      remove :slug
    end

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
    alter table(:polos) do
      add :slug, :citext
    end

    execute("ALTER TABLE polos NO FORCE ROW LEVEL SECURITY")

    execute("""
    UPDATE polos
    SET slug = (
      SELECT polo_routes.slug
      FROM polo_routes
      WHERE polo_routes.polo_id = polos.id
    )
    WHERE EXISTS (
      SELECT 1
      FROM polo_routes
      WHERE polo_routes.polo_id = polos.id
    )
    """)

    execute("""
    DO $$
    DECLARE
      orphan_id uuid;
      candidate text;
      attempt integer;
    BEGIN
      FOR orphan_id IN
        SELECT id
        FROM polos
        WHERE slug IS NULL
        ORDER BY id
      LOOP
        attempt := 0;

        LOOP
          candidate :=
            'polo-' || replace(orphan_id::text, '-', '') ||
            CASE WHEN attempt = 0 THEN '' ELSE '-' || attempt::text END;

          EXIT WHEN NOT EXISTS (
            SELECT 1
            FROM polos
            WHERE slug = candidate
          );

          attempt := attempt + 1;
        END LOOP;

        UPDATE polos
        SET slug = candidate
        WHERE id = orphan_id;
      END LOOP;
    END
    $$
    """)

    execute("ALTER TABLE polos FORCE ROW LEVEL SECURITY")

    alter table(:polos) do
      modify :slug, :citext, null: false
    end

    create unique_index(:polos, [:slug])

    drop table(:polo_routes)
  end
end
