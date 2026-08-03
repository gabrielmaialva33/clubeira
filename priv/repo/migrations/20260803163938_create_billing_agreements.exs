defmodule Clubeira.Repo.Migrations.CreateBillingAgreements do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:billing_agreements, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false
      add :user_id, references(:users, type: :uuid, on_delete: :restrict), null: false

      add :product_offering_version_id,
          references(:product_offering_versions,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :billing_agreements_offering_version_fkey,
            on_delete: :restrict
          ),
          null: false

      add :merchant_account_id,
          references(:merchant_accounts, type: :uuid, on_delete: :restrict),
          null: false

      add :provider_reference, :text, null: false
      add :status, :text, null: false, default: "pending"
      add :current_period, :tstzrange
      add :next_charge_at, :timestamptz
      add :cancelled_at, :timestamptz

      timestamps(@timestamps_opts)
    end

    create unique_index(:billing_agreements, [:id, :polo_id],
             name: :billing_agreements_id_polo_uidx
           )

    create unique_index(:billing_agreements, [:merchant_account_id, :provider_reference],
             name: :billing_agreements_provider_reference_uidx
           )

    create index(:billing_agreements, [:polo_id, :user_id])

    create constraint(:billing_agreements, :billing_agreements_status_check,
             check:
               "status IN ('pending', 'active', 'past_due', 'suspended', 'cancelled', 'expired')"
           )

    create constraint(:billing_agreements, :billing_agreements_period_check,
             check:
               "current_period IS NULL OR (NOT isempty(current_period) AND NOT lower_inf(current_period) AND NOT upper_inf(current_period) AND lower_inc(current_period) AND NOT upper_inc(current_period))"
           )
  end
end
