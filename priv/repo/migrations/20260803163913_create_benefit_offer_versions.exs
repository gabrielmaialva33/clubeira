defmodule Clubeira.Repo.Migrations.CreateBenefitOfferVersions do
  use Ecto.Migration

  def change do
    create table(:benefit_offer_versions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false

      add :benefit_offer_id,
          references(:benefit_offers,
            type: :uuid,
            with: [polo_id: :polo_id],
            name: :benefit_offer_versions_offer_fkey,
            on_delete: :restrict
          ),
          null: false

      add :version, :integer, null: false
      add :title, :text, null: false
      add :description, :text, null: false
      add :terms, :text, null: false
      add :redemption_instructions, :text, null: false
      add :percentage_value, :decimal, precision: 7, scale: 4
      add :amount_value, :decimal, precision: 14, scale: 2
      add :currency, :string, size: 3
      add :effective_during, :tstzrange, null: false
      add :status, :text, null: false, default: "draft"
      add :published_at, :timestamptz
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create unique_index(:benefit_offer_versions, [:polo_id, :benefit_offer_id, :version],
             name: :benefit_offer_versions_number_uidx
           )

    create unique_index(:benefit_offer_versions, [:id, :polo_id],
             name: :benefit_offer_versions_id_polo_uidx
           )

    create constraint(:benefit_offer_versions, :benefit_offer_versions_version_check,
             check: "version > 0"
           )

    create constraint(:benefit_offer_versions, :benefit_offer_versions_value_check,
             check:
               "(percentage_value IS NULL OR percentage_value > 0) AND (amount_value IS NULL OR amount_value >= 0) AND ((amount_value IS NULL AND currency IS NULL) OR (amount_value IS NOT NULL AND currency IS NOT NULL))"
           )

    create constraint(:benefit_offer_versions, :benefit_offer_versions_currency_check,
             check:
               "currency IS NULL OR (currency = upper(currency) AND char_length(currency) = 3)"
           )

    create constraint(:benefit_offer_versions, :benefit_offer_versions_status_check,
             check: "status IN ('draft', 'published', 'retired')"
           )

    create constraint(:benefit_offer_versions, :benefit_offer_versions_effective_check,
             check:
               "NOT isempty(effective_during) AND NOT lower_inf(effective_during) AND lower_inc(effective_during) AND NOT upper_inc(effective_during)"
           )

    execute(
      """
      ALTER TABLE benefit_offer_versions
      ADD CONSTRAINT benefit_offer_versions_published_effective_excl
      EXCLUDE USING gist (
        polo_id WITH =,
        benefit_offer_id WITH =,
        effective_during WITH &&
      )
      WHERE (status = 'published')
      """,
      """
      ALTER TABLE benefit_offer_versions
      DROP CONSTRAINT benefit_offer_versions_published_effective_excl
      """
    )
  end
end
