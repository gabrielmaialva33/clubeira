defmodule Clubeira.Repo.Migrations.CreatePaymentProviderEvents do
  use Ecto.Migration

  def change do
    create table(:payment_provider_events, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")

      add :payment_provider_id,
          references(:payment_providers, type: :uuid, on_delete: :restrict),
          null: false

      add :merchant_account_id,
          references(:merchant_accounts,
            type: :uuid,
            with: [payment_provider_id: :payment_provider_id],
            name: :payment_provider_events_account_fkey,
            on_delete: :restrict
          ),
          null: false

      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict)
      add :external_event_id, :text, null: false
      add :event_type, :text, null: false
      add :payload, :map, null: false
      add :payload_sha256, :binary, null: false
      add :received_at, :timestamptz, null: false, default: fragment("now()")
      add :processed_at, :timestamptz
      add :processing_error, :text
    end

    create unique_index(
             :payment_provider_events,
             [:payment_provider_id, :merchant_account_id, :external_event_id],
             name: :payment_provider_events_external_uidx
           )

    create index(:payment_provider_events, [:processed_at],
             where: "processed_at IS NULL",
             name: :payment_provider_events_pending_idx
           )
  end
end
