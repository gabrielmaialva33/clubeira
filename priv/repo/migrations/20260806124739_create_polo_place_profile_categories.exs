defmodule Clubeira.Repo.Migrations.CreatePoloPlaceProfileCategories do
  use Ecto.Migration

  def change do
    create table(:polo_place_profile_categories, primary_key: false) do
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict),
        primary_key: true,
        null: false

      add :polo_place_profile_id,
          references(:polo_place_profiles,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :polo_place_profile_categories_profile_fkey,
            on_delete: :restrict
          ),
          primary_key: true,
          null: false

      add :place_category_id,
          references(:place_categories, type: :uuid, on_delete: :restrict),
          primary_key: true,
          null: false

      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:polo_place_profile_categories, [:place_category_id])
    enable_tenant_rls(:polo_place_profile_categories)
  end

  defp enable_tenant_rls(table) do
    execute(
      "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY"
    )

    execute(
      "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY",
      "ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY"
    )

    execute(
      """
      CREATE POLICY polo_isolation ON #{table}
      FOR ALL
      USING (
        polo_id = NULLIF(current_setting('app.current_polo_id', true), '')::uuid
      )
      WITH CHECK (
        polo_id = NULLIF(current_setting('app.current_polo_id', true), '')::uuid
      )
      """,
      "DROP POLICY polo_isolation ON #{table}"
    )
  end
end
