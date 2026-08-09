defmodule Clubeira.Partnerships.DatabaseContractTest do
  use Clubeira.DataCase, async: true

  alias Clubeira.Repo

  test "agreement assignments cannot cross polo-owned editions, places or offers" do
    constraints = constraint_definitions()

    assert constraints["partner_agreement_polo_places_participation_fkey"] =~
             "FOREIGN KEY (polo_place_id, polo_id)"

    assert constraints["partner_agreement_editions_edition_fkey"] =~
             "FOREIGN KEY (edition_id, polo_id)"

    assert constraints["partner_agreement_offer_versions_offer_fkey"] =~
             "FOREIGN KEY (benefit_offer_version_id, polo_id)"
  end

  test "published terms are versioned, non-overlapping and append-only" do
    constraints = constraint_definitions()

    assert constraints["partner_agreement_terms_no_overlap"] =~
             "EXCLUDE USING gist"

    assert constraints["partner_agreement_terms_no_overlap"] =~
             "effective_during WITH &&"

    assert %{rows: [["partner_agreement_terms_append_only"]]} =
             Repo.query!("""
             SELECT trigger.tgname
             FROM pg_trigger AS trigger
             WHERE trigger.tgrelid = 'public.partner_agreement_terms'::regclass
               AND trigger.tgname = 'partner_agreement_terms_append_only'
               AND NOT trigger.tgisinternal
             """)
  end

  defp constraint_definitions do
    %{rows: rows} =
      Repo.query!("""
      SELECT constraint_record.conname, pg_get_constraintdef(constraint_record.oid)
      FROM pg_constraint AS constraint_record
      WHERE constraint_record.conname IN (
        'partner_agreement_polo_places_participation_fkey',
        'partner_agreement_editions_edition_fkey',
        'partner_agreement_offer_versions_offer_fkey',
        'partner_agreement_terms_no_overlap'
      )
      """)

    Map.new(rows, fn [name, definition] -> {name, definition} end)
  end
end
