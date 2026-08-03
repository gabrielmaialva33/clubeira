defmodule Clubeira.Repo.Migrations.CreatePoloPolicyVersions do
  use Ecto.Migration

  def change do
    create table(:polo_policy_versions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false
      add :version, :integer, null: false
      add :effective_during, :tstzrange, null: false
      add :redemption_confirmation_mode, :text, null: false, default: "two_party"
      add :redemption_device_policy, :text, null: false, default: "authorized_devices"
      add :max_authorized_devices, :smallint, null: false, default: 3
      add :delinquency_mode, :text, null: false, default: "grace_period"
      add :delinquency_grace_days, :smallint, null: false, default: 3
      add :review_policy, :text, null: false, default: "verified_only"
      add :published_at, :timestamptz, null: false
      add :retired_at, :timestamptz
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:polo_policy_versions, [:polo_id, :version])

    create unique_index(:polo_policy_versions, [:id, :polo_id], name: :polo_policies_id_polo_uidx)

    create constraint(:polo_policy_versions, :polo_policy_versions_version_check,
             check: "version > 0"
           )

    create constraint(:polo_policy_versions, :polo_policy_versions_effective_check,
             check:
               "NOT isempty(effective_during) AND NOT lower_inf(effective_during) AND lower_inc(effective_during) AND NOT upper_inc(effective_during)"
           )

    create constraint(:polo_policy_versions, :polo_policy_versions_no_overlap,
             exclude: "gist (polo_id WITH =, effective_during WITH &&)"
           )

    create constraint(:polo_policy_versions, :polo_policy_versions_confirmation_check,
             check:
               "redemption_confirmation_mode IN ('merchant_only', 'member_only', 'two_party')"
           )

    create constraint(:polo_policy_versions, :polo_policy_versions_device_policy_check,
             check: "redemption_device_policy IN ('any_authenticated', 'authorized_devices')"
           )

    create constraint(:polo_policy_versions, :polo_policy_versions_devices_check,
             check: "max_authorized_devices > 0"
           )

    create constraint(:polo_policy_versions, :polo_policy_versions_delinquency_check,
             check:
               "delinquency_mode IN ('immediate_block', 'grace_period') AND delinquency_grace_days >= 0"
           )

    create constraint(:polo_policy_versions, :polo_policy_versions_review_check,
             check: "review_policy IN ('open', 'verified_only', 'disabled')"
           )
  end
end
