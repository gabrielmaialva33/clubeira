defmodule Clubeira.Repo.Migrations.CreatePlatformPrices do
  use Ecto.Migration

  def change do
    create table(:platform_prices, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")

      add :platform_plan_version_id,
          references(:platform_plan_versions, type: :uuid, on_delete: :restrict),
          null: false

      add :currency, :string, size: 3, null: false
      add :amount, :decimal, precision: 14, scale: 2, null: false
      add :billing_interval_unit, :text, null: false
      add :billing_interval_count, :smallint, null: false, default: 1
      add :valid_during, :tstzrange, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:platform_prices, [:platform_plan_version_id])

    create constraint(:platform_prices, :platform_prices_amount_check, check: "amount >= 0")

    create constraint(:platform_prices, :platform_prices_currency_check,
             check: "currency = upper(currency) AND char_length(currency) = 3"
           )

    create constraint(:platform_prices, :platform_prices_interval_check,
             check: "billing_interval_unit IN ('month', 'year') AND billing_interval_count > 0"
           )

    create constraint(:platform_prices, :platform_prices_range_check,
             check:
               "NOT isempty(valid_during) AND NOT lower_inf(valid_during) AND lower_inc(valid_during) AND NOT upper_inc(valid_during)"
           )

    create constraint(:platform_prices, :platform_prices_no_overlap,
             exclude:
               "gist (platform_plan_version_id WITH =, currency WITH =, valid_during WITH &&)"
           )
  end
end
