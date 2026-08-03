defmodule Clubeira.Repo.Migrations.ReferenceTimeZonesFromCities do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE cities
    ADD CONSTRAINT cities_timezone_fkey
    FOREIGN KEY (timezone)
    REFERENCES time_zones (name)
    ON DELETE RESTRICT
    """)
  end

  def down do
    execute("ALTER TABLE cities DROP CONSTRAINT cities_timezone_fkey")
  end
end
