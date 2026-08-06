defmodule Clubeira.Directory.PlaceProfileDatabaseContractTest do
  use Clubeira.DataCase, async: true

  alias Clubeira.Directory
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  test "profile relations preserve the polo dimension through composite foreign keys" do
    definitions = constraint_definitions()

    assert definitions["polo_place_profiles_polo_place_fkey"] =~
             "FOREIGN KEY (polo_place_id, polo_id)"

    assert definitions["polo_place_profiles_polo_place_fkey"] =~
             "REFERENCES polo_places(id, polo_id)"

    assert definitions["polo_place_profile_categories_profile_fkey"] =~
             "FOREIGN KEY (polo_place_profile_id, polo_id)"

    assert definitions["polo_place_profile_categories_profile_fkey"] =~
             "REFERENCES polo_place_profiles(id, polo_id)"

    assert definitions["polo_place_opening_periods_profile_fkey"] =~
             "FOREIGN KEY (polo_place_profile_id, polo_id)"

    assert definitions["polo_place_opening_periods_profile_fkey"] =~
             "REFERENCES polo_place_profiles(id, polo_id)"
  end

  test "a profile cannot point to a participation owned by another polo" do
    fixture = RedemptionsFixtures.create!()
    other_polo = RedemptionsFixtures.create!()

    error =
      assert_raise Postgrex.Error, fn ->
        RedemptionsFixtures.scoped_query!(
          fixture,
          """
          INSERT INTO polo_place_profiles (
            id,
            polo_id,
            polo_place_id,
            public_email,
            public_phone,
            revision
          )
          VALUES ($1, $2, $3, 'cross-polo@example.test', '+5588999990104', 1)
          """,
          [uuid7(), fixture.ids.polo, other_polo.ids.polo_place]
        )
      end

    assert error.postgres.code == :foreign_key_violation
    assert error.postgres.constraint == "polo_place_profiles_polo_place_fkey"
  end

  test "the database rejects a weekly overlap across the Sunday-to-Monday boundary" do
    fixture = published_profile_fixture!()

    error =
      assert_raise Postgrex.Error, fn ->
        RedemptionsFixtures.scoped_query!(
          fixture,
          """
          INSERT INTO polo_place_opening_periods (
            id,
            polo_id,
            polo_place_profile_id,
            kind,
            weekday,
            opens_at,
            closes_at,
            closes_next_day
          )
          VALUES ($1, $2, $3, 'weekly', 1, time '01:00', time '04:00', false)
          """,
          [uuid7(), fixture.ids.polo, fixture.profile_id]
        )
      end

    assert error.postgres.code == :exclusion_violation
    assert error.postgres.constraint == "polo_place_opening_periods_weekly_overlap_excl"
  end

  test "a closed exception cannot coexist with custom hours on the same date" do
    fixture = published_profile_fixture!()

    error =
      assert_raise Postgrex.Error, fn ->
        RedemptionsFixtures.scoped_query!(
          fixture,
          """
          INSERT INTO polo_place_opening_periods (
            id,
            polo_id,
            polo_place_profile_id,
            kind,
            local_date,
            closes_next_day
          )
          VALUES ($1, $2, $3, 'exception_closed', date '2026-12-31', false)
          """,
          [uuid7(), fixture.ids.polo, fixture.profile_id]
        )
      end

    assert error.postgres.code == :exclusion_violation
    assert error.postgres.constraint == "polo_place_opening_periods_exception_overlap_excl"
  end

  defp published_profile_fixture! do
    fixture = RedemptionsFixtures.create!()
    scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    category = insert(:place_category)

    assert {:ok, _result} =
             Directory.publish_place_profile(scope, fixture.ids.place, %{
               contact: %{
                 email: "contrato@parceiro.example",
                 phone: "+5588999990105"
               },
               category_keys: [category.key],
               weekly_hours: [
                 %{weekday: 7, opens_at: "22:00", closes_at: "02:00"}
               ],
               special_hours: [
                 %{
                   date: "2026-12-31",
                   kind: "custom",
                   windows: [%{opens_at: "20:00", closes_at: "23:00"}]
                 }
               ],
               idempotency_key: "profile-database-contract-#{uuid7()}"
             })

    %{rows: [[profile_id]]} =
      RedemptionsFixtures.scoped_query!(
        fixture,
        "SELECT id FROM polo_place_profiles WHERE polo_place_id = $1",
        [fixture.ids.polo_place]
      )

    Map.put(fixture, :profile_id, Ecto.UUID.load!(profile_id))
  end

  defp constraint_definitions do
    %{rows: rows} =
      Repo.query!("""
      SELECT constraint_record.conname, pg_get_constraintdef(constraint_record.oid)
      FROM pg_constraint AS constraint_record
      WHERE constraint_record.conname IN (
        'polo_place_profiles_polo_place_fkey',
        'polo_place_profile_categories_profile_fkey',
        'polo_place_opening_periods_profile_fkey'
      )
      """)

    Map.new(rows, fn [name, definition] -> {name, definition} end)
  end

  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
