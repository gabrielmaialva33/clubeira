defmodule Clubeira.Redemptions.ConcurrencyTest do
  use Clubeira.ConcurrencyCase, async: false

  alias Clubeira.Redemptions
  alias Clubeira.RedemptionsFixtures

  test "serializes competing confirmations for the final entitlement unit", %{repo: repo} do
    fixture = RedemptionsFixtures.create!()
    competing_request = RedemptionsFixtures.request(fixture, %{})

    results =
      run_concurrently(repo, [
        fn -> Redemptions.confirm(fixture.scope, fixture.request) end,
        fn -> Redemptions.confirm(fixture.scope, competing_request) end
      ])

    assert Enum.count(results, &match?({:ok, _redemption}, &1)) == 1
    assert Enum.count(results, &match?({:error, :entitlement_exhausted}, &1)) == 1

    assert %{rows: [[0, 1, 2]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 (SELECT available_units FROM entitlement_allocations WHERE id = $1),
                 (SELECT count(*) FROM redemptions WHERE polo_id = $2),
                 (SELECT count(*) FROM redemption_attempts WHERE polo_id = $2)
               """,
               [fixture.ids.entitlement_allocation, fixture.ids.polo]
             )
  end

  test "replays one committed result for concurrent retries of the same request", %{repo: repo} do
    fixture = RedemptionsFixtures.create!()

    results =
      run_concurrently(repo, [
        fn -> Redemptions.confirm(fixture.scope, fixture.request) end,
        fn -> Redemptions.confirm(fixture.scope, fixture.request) end
      ])

    assert [{:ok, first}, {:ok, second}] = results
    assert first.id == second.id

    assert %{rows: [[1, 1, 1]]} =
             RedemptionsFixtures.scoped_query!(
               fixture,
               """
               SELECT
                 (SELECT count(*) FROM redemptions WHERE polo_id = $1),
                 (SELECT count(*) FROM redemption_attempts WHERE polo_id = $1),
                 (SELECT count(*) FROM tenant_idempotency_keys WHERE polo_id = $1)
               """,
               [fixture.ids.polo]
             )
  end
end
