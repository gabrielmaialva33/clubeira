defmodule Clubeira.Repo.Migrations.CreateProductOfferings do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:product_offerings, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :access_product_version_id,
          references(:access_product_versions,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :product_offerings_product_version_fkey,
            on_delete: :restrict
          ),
          null: false

      add :edition_id,
          references(:editions,
            type: :uuid,
            with: [polo_id: :polo_id],
            match: :simple,
            name: :product_offerings_edition_fkey,
            on_delete: :restrict
          )

      add :code, :citext, null: false
      add :scope_kind, :text, null: false
      add :sales_channel, :text, null: false, default: "direct"
      add :status, :text, null: false, default: "draft"
      add :revision, :integer, null: false, default: 1

      timestamps(@timestamps_opts)
    end

    create unique_index(:product_offerings, [:polo_id, :code])

    create unique_index(:product_offerings, [:id, :polo_id],
             name: :product_offerings_id_polo_uidx
           )

    create index(:product_offerings, [:edition_id])

    create index(:product_offerings, [:polo_id, :inserted_at, :id],
             name: :product_offerings_backoffice_feed_idx
           )

    create index(:product_offerings, [:polo_id, :status, :inserted_at, :id],
             name: :product_offerings_backoffice_status_feed_idx
           )

    create constraint(:product_offerings, :product_offerings_revision_check,
             check: "revision > 0"
           )

    create constraint(:product_offerings, :product_offerings_scope_check,
             check:
               "(scope_kind = 'edition' AND edition_id IS NOT NULL) OR (scope_kind = 'evergreen' AND edition_id IS NULL)"
           )

    create constraint(:product_offerings, :product_offerings_channel_check,
             check: "sales_channel IN ('direct', 'partner', 'admin')"
           )

    create constraint(:product_offerings, :product_offerings_status_check,
             check: "status IN ('draft', 'active', 'paused', 'retired')"
           )
  end
end
