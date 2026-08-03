defmodule Clubeira.Repo.Migrations.CreatePoloPlatformSubscriptions do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:polo_platform_subscriptions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :platform_plan_version_id,
          references(:platform_plan_versions, type: :uuid, on_delete: :restrict),
          null: false

      add :platform_price_id,
          references(:platform_prices, type: :uuid, on_delete: :restrict),
          null: false

      add :merchant_account_id,
          references(:merchant_accounts, type: :uuid, on_delete: :restrict),
          null: false

      add :provider_reference, :text, null: false
      add :status, :text, null: false, default: "pending"
      add :current_period, :tstzrange
      add :cancelled_at, :timestamptz

      timestamps(@timestamps_opts)
    end

    create unique_index(:polo_platform_subscriptions, [:id, :polo_id],
             name: :polo_platform_subscriptions_id_polo_uidx
           )

    create unique_index(
             :polo_platform_subscriptions,
             [:merchant_account_id, :provider_reference],
             name: :polo_platform_subscriptions_provider_uidx
           )

    create unique_index(
             :polo_platform_subscriptions,
             [:polo_id, :platform_plan_version_id],
             where: "status IN ('pending', 'active', 'past_due', 'suspended')",
             name: :polo_platform_subscriptions_current_uidx
           )

    create constraint(
             :polo_platform_subscriptions,
             :polo_platform_subscriptions_status_check,
             check:
               "status IN ('pending', 'active', 'past_due', 'suspended', 'cancelled', 'expired')"
           )

    create constraint(
             :polo_platform_subscriptions,
             :polo_platform_subscriptions_period_check,
             check:
               "current_period IS NULL OR (NOT isempty(current_period) AND NOT lower_inf(current_period) AND NOT upper_inf(current_period) AND lower_inc(current_period) AND NOT upper_inc(current_period))"
           )
  end
end
