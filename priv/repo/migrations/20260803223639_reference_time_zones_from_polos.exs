defmodule Clubeira.Repo.Migrations.ReferenceTimeZonesFromPolos do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE polos
    ADD CONSTRAINT polos_timezone_fkey
    FOREIGN KEY (timezone)
    REFERENCES time_zones (name)
    ON DELETE RESTRICT
    """)
  end

  def down do
    execute("ALTER TABLE polos DROP CONSTRAINT polos_timezone_fkey")
  end
end
