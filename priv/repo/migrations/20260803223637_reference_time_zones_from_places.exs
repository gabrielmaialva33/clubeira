defmodule Clubeira.Repo.Migrations.ReferenceTimeZonesFromPlaces do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE places
    ADD CONSTRAINT places_timezone_fkey
    FOREIGN KEY (timezone)
    REFERENCES time_zones (name)
    ON DELETE RESTRICT
    """)
  end

  def down do
    execute("ALTER TABLE places DROP CONSTRAINT places_timezone_fkey")
  end
end
