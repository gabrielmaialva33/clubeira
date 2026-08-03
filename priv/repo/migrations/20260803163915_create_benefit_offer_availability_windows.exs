defmodule Clubeira.Repo.Migrations.CreateBenefitOfferAvailabilityWindows do
  use Ecto.Migration

  def change do
    create table(:benefit_offer_availability_windows, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :benefit_offer_version_id,
          references(:benefit_offer_versions,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :benefit_offer_availability_windows_offer_fkey,
            on_delete: :restrict
          ),
          null: false

      add :weekday, :smallint, null: false
      add :starts_at_local, :time, null: false
      add :ends_at_local, :time, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:benefit_offer_availability_windows, [:benefit_offer_version_id, :weekday],
             name: :benefit_offer_availability_lookup_idx
           )

    create constraint(
             :benefit_offer_availability_windows,
             :benefit_offer_availability_windows_weekday_check,
             check: "weekday BETWEEN 1 AND 7"
           )

    create constraint(
             :benefit_offer_availability_windows,
             :benefit_offer_availability_windows_time_check,
             check: "starts_at_local < ends_at_local"
           )
  end
end
