defmodule Clubeira.Catalog.DatabaseContractTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.RedemptionsFixtures

  test "published versions of the same offer cannot overlap" do
    fixture = RedemptionsFixtures.create!()

    error =
      assert_raise Postgrex.Error, fn ->
        clone_version!(fixture, status: "published", version: 2)
      end

    assert error.postgres.code == :exclusion_violation
    assert error.postgres.constraint == "benefit_offer_versions_published_effective_excl"

    assert %{num_rows: 1} = clone_version!(fixture, status: "draft", version: 2)
  end

  test "published version values must match their stable benefit kind" do
    complimentary = RedemptionsFixtures.create!()

    error =
      assert_raise Postgrex.Error, fn ->
        RedemptionsFixtures.scoped_query!(
          complimentary,
          """
          UPDATE benefit_offer_versions
          SET percentage_value = 10
          WHERE id = $1
          """,
          [complimentary.ids.benefit_offer_version]
        )
      end

    assert error.postgres.code == :check_violation
    assert error.postgres.constraint == "benefit_offer_versions_kind_value_check"

    incomplete_percentage =
      RedemptionsFixtures.create!(
        benefit_kind: "discount_percentage",
        offer_version_status: "draft"
      )

    error =
      assert_raise Postgrex.Error, fn ->
        RedemptionsFixtures.scoped_query!(
          incomplete_percentage,
          """
          UPDATE benefit_offer_versions
          SET status = 'published', published_at = statement_timestamp()
          WHERE id = $1
          """,
          [incomplete_percentage.ids.benefit_offer_version]
        )
      end

    assert error.postgres.code == :check_violation
    assert error.postgres.constraint == "benefit_offer_versions_kind_value_check"

    assert %{ids: %{benefit_offer_version: version_id}} =
             RedemptionsFixtures.create!(
               benefit_kind: "discount_amount",
               amount_value: Decimal.new("9.90"),
               currency: "BRL"
             )

    assert is_binary(version_id)
  end

  test "benefit kind is immutable after the first version exists" do
    fixture = RedemptionsFixtures.create!()

    error =
      assert_raise Postgrex.Error, fn ->
        RedemptionsFixtures.scoped_query!(
          fixture,
          """
          UPDATE benefit_offers
          SET benefit_kind = 'custom'
          WHERE id = $1
          """,
          [fixture.ids.benefit_offer]
        )
      end

    assert error.postgres.code == :check_violation
    assert error.postgres.constraint == "benefit_offers_kind_immutable_check"
  end

  defp clone_version!(fixture, options) do
    status = Keyword.fetch!(options, :status)
    version = Keyword.fetch!(options, :version)
    published_at = if status == "published", do: fixture.now

    RedemptionsFixtures.scoped_query!(
      fixture,
      """
      INSERT INTO benefit_offer_versions (
        id,
        polo_id,
        benefit_offer_id,
        version,
        title,
        description,
        terms,
        redemption_instructions,
        percentage_value,
        amount_value,
        currency,
        effective_during,
        status,
        published_at
      )
      SELECT
        $1,
        polo_id,
        benefit_offer_id,
        $2,
        title,
        description,
        terms,
        redemption_instructions,
        percentage_value,
        amount_value,
        currency,
        effective_during,
        $3,
        $4
      FROM benefit_offer_versions
      WHERE id = $5
      """,
      [
        Ecto.UUID.generate(version: 7, precision: :monotonic),
        version,
        status,
        published_at,
        fixture.ids.benefit_offer_version
      ]
    )
  end
end
