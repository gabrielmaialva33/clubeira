defmodule Clubeira.Repo.Migrations.CreateBenefitOfferBlackoutPeriods do
  use Ecto.Migration

  def change do
    create table(:benefit_offer_blackout_periods, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :benefit_offer_version_id,
          references(:benefit_offer_versions,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :benefit_offer_blackout_periods_offer_fkey,
            on_delete: :restrict
          ),
          null: false

      add :blackout_during, :tstzrange, null: false
      add :reason, :text
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:benefit_offer_blackout_periods, [:benefit_offer_version_id])

    create constraint(
             :benefit_offer_blackout_periods,
             :benefit_offer_blackout_periods_range_check,
             check:
               "NOT isempty(blackout_during) AND NOT lower_inf(blackout_during) AND NOT upper_inf(blackout_during) AND lower_inc(blackout_during) AND NOT upper_inc(blackout_during)"
           )
  end
end
