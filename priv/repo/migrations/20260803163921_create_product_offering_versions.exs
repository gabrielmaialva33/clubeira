defmodule Clubeira.Repo.Migrations.CreateProductOfferingVersions do
  use Ecto.Migration

  def change do
    create table(:product_offering_versions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :product_offering_id,
          references(:product_offerings,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :product_offering_versions_offering_fkey,
            on_delete: :restrict
          ),
          null: false

      add :version, :integer, null: false
      add :name, :text, null: false
      add :description, :text, null: false
      add :effective_during, :tstzrange, null: false
      add :activation_policy, :text, null: false
      add :cycle_policy, :text, null: false
      add :cycle_interval_unit, :text
      add :cycle_interval_count, :smallint
      add :renewal_policy, :text, null: false, default: "none"
      add :minimum_beneficiaries, :smallint, null: false, default: 1
      add :maximum_beneficiaries, :smallint, null: false, default: 1
      add :delinquency_grace_days_override, :smallint
      add :status, :text, null: false, default: "draft"
      add :published_at, :timestamptz
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(
             :product_offering_versions,
             [:polo_id, :product_offering_id, :version],
             name: :product_offering_versions_number_uidx
           )

    create unique_index(:product_offering_versions, [:id, :polo_id],
             name: :product_offering_versions_id_polo_uidx
           )

    create constraint(:product_offering_versions, :product_offering_versions_version_check,
             check: "version > 0"
           )

    create constraint(:product_offering_versions, :product_offering_versions_effective_check,
             check:
               "NOT isempty(effective_during) AND NOT lower_inf(effective_during) AND lower_inc(effective_during) AND NOT upper_inc(effective_during)"
           )

    create constraint(:product_offering_versions, :product_offering_versions_activation_check,
             check:
               "activation_policy IN ('edition_start', 'payment_confirmation', 'first_redemption', 'manual')"
           )

    create constraint(:product_offering_versions, :product_offering_versions_cycle_check,
             check:
               "(cycle_policy IN ('anniversary', 'calendar') AND cycle_interval_unit IN ('day', 'month', 'year') AND cycle_interval_count > 0) OR (cycle_policy IN ('single', 'explicit') AND cycle_interval_unit IS NULL AND cycle_interval_count IS NULL)"
           )

    create constraint(:product_offering_versions, :product_offering_versions_renewal_check,
             check: "renewal_policy IN ('none', 'manual', 'automatic')"
           )

    create constraint(:product_offering_versions, :product_offering_versions_beneficiaries_check,
             check: "minimum_beneficiaries > 0 AND maximum_beneficiaries >= minimum_beneficiaries"
           )

    create constraint(:product_offering_versions, :product_offering_versions_grace_check,
             check:
               "delinquency_grace_days_override IS NULL OR delinquency_grace_days_override >= 0"
           )

    create constraint(:product_offering_versions, :product_offering_versions_status_check,
             check: "status IN ('draft', 'published', 'retired')"
           )
  end
end
