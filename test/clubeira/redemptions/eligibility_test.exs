defmodule Clubeira.Redemptions.EligibilityTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Redemptions
  alias Clubeira.RedemptionsFixtures

  test "rejects an unavailable validation point" do
    fixture = RedemptionsFixtures.create!()

    assert_rejected(fixture, :validation_point_unavailable, %{
      validation_point_id: Ecto.UUID.generate()
    })
  end

  test "rejects an unavailable polo place" do
    fixture = RedemptionsFixtures.create!(polo_place_status: "suspended")
    assert_rejected(fixture, :place_unavailable)
  end

  test "rejects an unavailable device installation" do
    fixture = RedemptionsFixtures.create!()

    assert_rejected(fixture, :device_unavailable, %{
      device_installation_id: Ecto.UUID.generate()
    })
  end

  test "rejects an inactive access contract" do
    fixture = RedemptionsFixtures.create!(contract_status: "cancelled")
    assert_rejected(fixture, :contract_inactive)
  end

  test "rejects an inactive benefit cycle" do
    fixture = RedemptionsFixtures.create!(cycle_status: "closed")
    assert_rejected(fixture, :cycle_inactive)
  end

  test "prevents an allocation inconsistent with its package item" do
    error =
      assert_raise Postgrex.Error, fn ->
        RedemptionsFixtures.create!(invalid_entitlement_configuration: true)
      end

    assert error.postgres.constraint == "entitlement_allocations_package_item_fkey"
  end

  test "rejects an inactive benefit offer" do
    fixture = RedemptionsFixtures.create!(offer_status: "retired")
    assert_rejected(fixture, :offer_inactive)
  end

  test "rejects an offer not published at the validation place" do
    fixture = RedemptionsFixtures.create!(offer_available_at_place: false)
    assert_rejected(fixture, :offer_not_available_at_place)
  end

  test "rejects an offer outside its local availability window" do
    fixture = RedemptionsFixtures.create!(outside_availability_window: true)
    assert_rejected(fixture, :outside_availability_window)
  end

  test "rejects a per-place allocation at another configured place" do
    fixture = RedemptionsFixtures.create!(alternate_validation_place: true)

    assert_rejected(fixture, :allocation_not_valid_at_place, %{
      validation_point_id: fixture.ids.other_validation_point
    })
  end

  defp assert_rejected(fixture, reason, request_overrides \\ %{}) do
    request = RedemptionsFixtures.request(fixture, request_overrides)
    assert {:error, ^reason} = Redemptions.confirm(fixture.scope, request)
  end
end
