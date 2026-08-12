defmodule Clubeira.Types.TstzRangeTest do
  use ExUnit.Case, async: true

  alias Clubeira.Types.TstzRange

  test "casts, loads and dumps nullable valid timestamp ranges" do
    assert TstzRange.type() == :tstzrange

    range = %Postgrex.Range{
      lower: ~U[2026-08-12 12:00:00Z],
      upper: ~U[2026-08-13 12:00:00Z],
      lower_inclusive: true,
      upper_inclusive: false
    }

    for operation <- [&TstzRange.cast/1, &TstzRange.load/1, &TstzRange.dump/1] do
      assert operation.(nil) == {:ok, nil}
      assert operation.(range) == {:ok, range}
      assert operation.(%{lower: range.lower, upper: range.upper}) == :error
    end
  end

  test "accepts PostgreSQL sentinel bounds and rejects malformed range bounds" do
    for bound <- [:unbound, :empty] do
      range = %Postgrex.Range{lower: bound, upper: bound}
      assert TstzRange.cast(range) == {:ok, range}
    end

    assert TstzRange.cast(%Postgrex.Range{lower: 0, upper: :unbound}) == :error
  end
end
