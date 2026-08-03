defmodule Clubeira.Repo.Migrations.CreatePaymentProviders do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:payment_providers, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :code, :citext, null: false
      add :name, :text, null: false
      add :status, :text, null: false, default: "active"

      timestamps(@timestamps_opts)
    end

    create unique_index(:payment_providers, [:code])

    create constraint(:payment_providers, :payment_providers_status_check,
             check: "status IN ('active', 'disabled')"
           )
  end
end
