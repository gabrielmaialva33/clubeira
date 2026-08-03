defmodule Clubeira.Repo.Migrations.CreateBenefitOffers do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:benefit_offers, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false
      add :code, :citext, null: false
      add :name, :text, null: false
      add :benefit_kind, :text, null: false
      add :status, :text, null: false, default: "draft"

      timestamps(@timestamps_opts)
    end

    create unique_index(:benefit_offers, [:polo_id, :code])

    create unique_index(:benefit_offers, [:id, :polo_id], name: :benefit_offers_id_polo_uidx)

    create constraint(:benefit_offers, :benefit_offers_kind_check,
             check:
               "benefit_kind IN ('discount_percentage', 'discount_amount', 'complimentary_item', 'bundle', 'custom')"
           )

    create constraint(:benefit_offers, :benefit_offers_status_check,
             check: "status IN ('draft', 'active', 'retired')"
           )
  end
end
