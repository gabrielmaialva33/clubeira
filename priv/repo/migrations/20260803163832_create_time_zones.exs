defmodule Clubeira.Repo.Migrations.CreateTimeZones do
  use Ecto.Migration

  def change do
    create table(:time_zones, primary_key: false) do
      add :name, :text, primary_key: true
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    execute(
      """
      INSERT INTO time_zones (name)
      SELECT DISTINCT name
      FROM pg_timezone_names
      ORDER BY name
      """,
      "DELETE FROM time_zones"
    )
  end
end
