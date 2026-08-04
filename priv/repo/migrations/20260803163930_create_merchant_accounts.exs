defmodule Clubeira.Repo.Migrations.CreateMerchantAccounts do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:merchant_accounts, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")

      add :payment_provider_id,
          references(:payment_providers, type: :uuid, on_delete: :restrict),
          null: false

      add :kind, :text, null: false
      add :name, :text, null: false
      add :provider_account_reference, :text, null: false
      add :status, :text, null: false, default: "active"

      timestamps(@timestamps_opts)
    end

    create unique_index(:merchant_accounts, [:payment_provider_id, :provider_account_reference],
             name: :merchant_accounts_provider_reference_uidx
           )

    create unique_index(:merchant_accounts, [:id, :payment_provider_id],
             name: :merchant_accounts_provider_identity_uidx
           )

    create constraint(:merchant_accounts, :merchant_accounts_kind_check,
             check: "kind IN ('consumer', 'platform')"
           )

    create constraint(:merchant_accounts, :merchant_accounts_status_check,
             check: "status IN ('active', 'disabled')"
           )
  end
end
