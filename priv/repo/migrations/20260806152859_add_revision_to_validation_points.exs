defmodule Clubeira.Repo.Migrations.AddRevisionToValidationPoints do
  use Ecto.Migration

  def up do
    alter table(:validation_points) do
      add :revision, :integer, null: false, default: 1
    end

    create constraint(:validation_points, :validation_points_revision_check,
             check: "revision > 0"
           )

    execute("""
    UPDATE validation_points AS point
       SET revision = stream.revision
      FROM (
        SELECT polo_id, aggregate_id, max(aggregate_version) AS revision
          FROM domain_events
         WHERE aggregate_type = 'validation_point'
         GROUP BY polo_id, aggregate_id
      ) AS stream
     WHERE stream.polo_id = point.polo_id
       AND stream.aggregate_id = point.id
    """)
  end

  def down do
    drop constraint(:validation_points, :validation_points_revision_check)

    alter table(:validation_points) do
      remove :revision
    end
  end
end
