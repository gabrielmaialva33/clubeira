defmodule Clubeira.Repo.Migrations.CreateContractRedemptionDevices do
  use Ecto.Migration

  def change do
    create table(:contract_redemption_devices, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :access_contract_id,
          references(:access_contracts,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :contract_redemption_devices_contract_fkey,
            on_delete: :restrict
          ),
          null: false

      add :contract_beneficiary_id,
          references(:contract_beneficiaries,
            type: :uuid,
            with: [polo_id: :polo_id, access_contract_id: :access_contract_id],
            match: :simple,
            name: :contract_redemption_devices_beneficiary_fkey,
            on_delete: :restrict
          )

      add :device_installation_id,
          references(:device_installations, type: :uuid, on_delete: :restrict),
          null: false

      add :valid_during, :tstzrange, null: false
      add :status, :text, null: false, default: "active"
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:contract_redemption_devices, [:id, :polo_id],
             name: :contract_redemption_devices_id_polo_uidx
           )

    create index(
             :contract_redemption_devices,
             [:polo_id, :access_contract_id, :device_installation_id],
             name: :contract_redemption_devices_lookup_idx
           )

    create constraint(:contract_redemption_devices, :contract_redemption_devices_status_check,
             check: "status IN ('active', 'revoked')"
           )

    create constraint(:contract_redemption_devices, :contract_redemption_devices_range_check,
             check:
               "NOT isempty(valid_during) AND NOT lower_inf(valid_during) AND lower_inc(valid_during) AND NOT upper_inc(valid_during)"
           )

    create constraint(:contract_redemption_devices, :contract_redemption_devices_no_overlap,
             exclude:
               "gist (access_contract_id WITH =, device_installation_id WITH =, valid_during WITH &&)"
           )
  end
end
