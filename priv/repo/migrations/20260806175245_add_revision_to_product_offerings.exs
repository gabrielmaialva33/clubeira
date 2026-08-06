defmodule Clubeira.Repo.Migrations.AddRevisionToProductOfferings do
  use Ecto.Migration

  def up do
    alter table(:product_offerings) do
      add :revision, :integer, null: false, default: 1
    end

    create constraint(:product_offerings, :product_offerings_revision_check,
             check: "revision > 0"
           )

    execute("""
    UPDATE product_offerings AS offering
       SET revision = stream.revision
      FROM (
        SELECT polo_id, aggregate_id, max(aggregate_version) AS revision
          FROM domain_events
         WHERE aggregate_type = 'product_offering'
         GROUP BY polo_id, aggregate_id
      ) AS stream
     WHERE stream.polo_id = offering.polo_id
       AND stream.aggregate_id = offering.id
    """)
  end

  def down do
    drop constraint(:product_offerings, :product_offerings_revision_check)

    alter table(:product_offerings) do
      remove :revision
    end
  end
end
