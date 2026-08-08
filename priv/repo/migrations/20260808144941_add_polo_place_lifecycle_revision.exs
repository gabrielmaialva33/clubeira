defmodule Clubeira.Repo.Migrations.AddPoloPlaceLifecycleRevision do
  use Ecto.Migration

  def change do
    alter table(:polo_places) do
      add :revision, :integer, null: false, default: 1
    end

    create constraint(:polo_places, :polo_places_revision_check, check: "revision > 0")
  end
end
