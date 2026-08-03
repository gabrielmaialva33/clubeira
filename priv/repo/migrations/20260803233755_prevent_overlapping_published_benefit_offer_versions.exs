defmodule Clubeira.Repo.Migrations.PreventOverlappingPublishedBenefitOfferVersions do
  use Ecto.Migration

  def change do
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
