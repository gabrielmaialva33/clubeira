defmodule Clubeira.Repo.Migrations.CreatePoloPlaceProfiles do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:polo_place_profiles, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :polo_place_id,
          references(:polo_places,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :polo_place_profiles_polo_place_fkey,
            on_delete: :restrict
          ),
          null: false

      add :public_email, :citext, null: false
      add :public_phone, :text, null: false
      add :revision, :integer, null: false, default: 1

      timestamps(@timestamps_opts)
    end

    create unique_index(:polo_place_profiles, [:id, :polo_id],
             name: :polo_place_profiles_id_polo_uidx
           )

    create unique_index(:polo_place_profiles, [:polo_id, :polo_place_id])

    create constraint(:polo_place_profiles, :polo_place_profiles_email_check,
             check:
               "char_length(public_email::text) BETWEEN 3 AND 254 AND public_email::text ~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'"
           )

    create constraint(:polo_place_profiles, :polo_place_profiles_phone_check,
             check: "public_phone ~ '^\\+[1-9][0-9]{7,14}$'"
           )

    create constraint(:polo_place_profiles, :polo_place_profiles_revision_check,
             check: "revision > 0"
           )

    enable_tenant_rls(:polo_place_profiles)
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
