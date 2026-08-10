defmodule Clubeira.Subscriptions.CycleScheduleTest do
  use Clubeira.DataCase, async: true

  alias Clubeira.Polos.Polo
  alias Clubeira.Subscriptions.CycleSchedule
  alias Clubeira.Subscriptions.ProductOfferingVersion

  test "calendar cycles follow the polo's local month boundaries" do
    version = version(cycle_policy: "calendar", cycle_interval_unit: "month")
    polo = %Polo{timezone: "America/Sao_Paulo"}

    assert {:ok, range} = CycleSchedule.bounds(Repo, version, polo, ~U[2026-08-15 14:00:00Z])
    assert range.lower == ~U[2026-08-01 03:00:00.000000Z]
    assert range.upper == ~U[2026-09-01 03:00:00.000000Z]
    assert range.lower_inclusive
    refute range.upper_inclusive
  end

  test "anniversary month cycles clamp end-of-month in local wall-clock time" do
    version = version(cycle_policy: "anniversary", cycle_interval_unit: "month")
    polo = %Polo{timezone: "America/Sao_Paulo"}

    assert {:ok, range} = CycleSchedule.bounds(Repo, version, polo, ~U[2024-01-31 15:00:00Z])
    assert range.lower == ~U[2024-01-31 15:00:00.000000Z]
    assert range.upper == ~U[2024-02-29 15:00:00.000000Z]
  end

  test "anniversary day cycles preserve local time across daylight-saving changes" do
    version = version(cycle_policy: "anniversary", cycle_interval_unit: "day")
    polo = %Polo{timezone: "America/New_York"}

    assert {:ok, range} = CycleSchedule.bounds(Repo, version, polo, ~U[2024-03-09 17:00:00Z])
    assert range.lower == ~U[2024-03-09 17:00:00.000000Z]
    assert range.upper == ~U[2024-03-10 16:00:00.000000Z]
  end

  test "rejects cycle policies that the first provisioning slice does not support" do
    version = version(cycle_policy: "single", cycle_interval_unit: nil, cycle_interval_count: nil)

    assert {:error, :unsupported_cycle_policy} =
             CycleSchedule.bounds(
               Repo,
               version,
               %Polo{timezone: "America/Sao_Paulo"},
               ~U[2026-08-01 00:00:00Z]
             )
  end

  defp version(overrides) do
    struct!(
      ProductOfferingVersion,
      Keyword.merge(
        [cycle_policy: "calendar", cycle_interval_unit: "month", cycle_interval_count: 1],
        overrides
      )
    )
  end
end
