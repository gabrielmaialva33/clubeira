defmodule Clubeira.Repo.Migrations.CreateAccessContracts do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:access_contracts, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false
      add :purchaser_user_id, references(:users, type: :uuid, on_delete: :restrict), null: false

      add :order_item_id,
          references(:order_items,
            type: :uuid,
            with: [
              polo_id: :polo_id,
              product_offering_version_id: :product_offering_version_id
            ],
            name: :access_contracts_order_item_fkey,
            on_delete: :restrict
          ),
          null: false

      add :product_offering_version_id,
          references(:product_offering_versions,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :access_contracts_offering_version_fkey,
            on_delete: :restrict
          ),
          null: false

      add :polo_policy_version_id,
          references(:polo_policy_versions,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :access_contracts_polo_policy_fkey,
            on_delete: :restrict
          ),
          null: false

      add :billing_agreement_id,
          references(:billing_agreements,
            type: :uuid,
            with: [polo_id: :polo_id],
            match: :simple,
            name: :access_contracts_billing_agreement_fkey,
            on_delete: :restrict
          )

      add :status, :text, null: false, default: "pending"
      add :starts_at, :timestamptz
      add :activated_at, :timestamptz
      add :ends_at, :timestamptz
      add :cancelled_at, :timestamptz

      timestamps(@timestamps_opts)
    end

    create unique_index(:access_contracts, [:id, :polo_id], name: :access_contracts_id_polo_uidx)

    create unique_index(:access_contracts, [:polo_id, :order_item_id],
             name: :access_contracts_order_item_uidx
           )

    create index(:access_contracts, [:purchaser_user_id, :status])
    create index(:access_contracts, [:polo_id, :product_offering_version_id])
    create index(:access_contracts, [:billing_agreement_id])

    create index(:access_contracts, [:polo_id, :inserted_at, :id],
             name: :access_contracts_backoffice_feed_idx
           )

    create index(:access_contracts, [:polo_id, :status, :inserted_at, :id],
             name: :access_contracts_backoffice_status_feed_idx
           )

    create constraint(:access_contracts, :access_contracts_status_check,
             check:
               "status IN ('pending', 'active', 'past_due', 'suspended', 'cancelled', 'expired')"
           )

    create constraint(:access_contracts, :access_contracts_dates_check,
             check:
               "(ends_at IS NULL OR starts_at IS NULL OR ends_at > starts_at) AND (cancelled_at IS NULL OR status = 'cancelled')"
           )
  end
end
