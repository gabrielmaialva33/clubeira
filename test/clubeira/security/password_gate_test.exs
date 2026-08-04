defmodule Clubeira.Security.PasswordGateTest do
  use ExUnit.Case, async: true

  alias Clubeira.Security.PasswordGate

  test "rejects overflow instead of queueing and releases permits" do
    gate = start_supervised!({PasswordGate, name: nil, max_concurrency: 1})
    parent = self()

    holder =
      Task.async(fn ->
        PasswordGate.run(gate, fn ->
          send(parent, :password_gate_acquired)

          receive do
            :release_password_gate -> :verified
          end
        end)
      end)

    assert_receive :password_gate_acquired
    assert PasswordGate.run(gate, fn -> :unreachable end) == {:error, :capacity_exhausted}

    send(holder.pid, :release_password_gate)
    assert Task.await(holder) == :verified
    assert PasswordGate.run(gate, fn -> :verified_again end) == :verified_again
  end
end
