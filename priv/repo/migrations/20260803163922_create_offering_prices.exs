defmodule Clubeira.Repo.Migrations.CreateOfferingPrices do
  use Ecto.Migration

  def change do
    create table(:offering_prices, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :product_offering_version_id,
          references(:product_offering_versions,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :offering_prices_offering_version_fkey,
            on_delete: :restrict
          ),
          null: false

      add :price_key, :text, null: false, default: "default"
      add :currency, :string, size: 3, null: false
      add :amount, :decimal, precision: 14, scale: 2, null: false
      add :billing_model, :text, null: false
      add :billing_interval_unit, :text
      add :billing_interval_count, :smallint
      add :installments, :smallint, null: false, default: 1
      add :valid_during, :tstzrange, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:offering_prices, [:id, :polo_id], name: :offering_prices_id_polo_uidx)
    create index(:offering_prices, [:polo_id, :product_offering_version_id])

    create constraint(:offering_prices, :offering_prices_amount_check,
             check: "amount >= 0 AND installments > 0"
           )

    create constraint(:offering_prices, :offering_prices_currency_check,
             check: "currency = upper(currency) AND char_length(currency) = 3"
           )

    create constraint(:offering_prices, :offering_prices_billing_check,
             check:
               "(billing_model = 'subscription' AND billing_interval_unit IN ('day', 'month', 'year') AND billing_interval_count > 0) OR (billing_model = 'one_time' AND billing_interval_unit IS NULL AND billing_interval_count IS NULL)"
           )

    create constraint(:offering_prices, :offering_prices_valid_during_check,
             check:
               "NOT isempty(valid_during) AND NOT lower_inf(valid_during) AND lower_inc(valid_during) AND NOT upper_inc(valid_during)"
           )

    create constraint(:offering_prices, :offering_prices_no_overlap,
             exclude:
               "gist (product_offering_version_id WITH =, price_key WITH =, valid_during WITH &&)"
           )
  end
end
