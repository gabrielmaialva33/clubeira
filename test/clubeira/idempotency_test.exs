defmodule Clubeira.IdempotencyTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Idempotency
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.Tenancy.Scope

  test "reports a deliberately persisted processing reservation" do
    fixture = RedemptionsFixtures.create!()
    scope = Scope.new!(fixture.ids.polo, request_id: Ecto.UUID.generate())
    request_hash = Idempotency.fingerprint({:test, fixture.ids.polo})
    now = DateTime.utc_now(:microsecond)

    assert {:ok, :reserved} =
             Repo.transact_in_polo(scope, fn repo ->
               assert {:new, _id} =
                        Idempotency.reserve(
                          repo,
                          scope,
                          "test.processing",
                          "processing-key",
                          request_hash,
                          now
                        )

               assert {:error, :request_in_progress} =
                        Idempotency.reserve(
                          repo,
                          scope,
                          "test.processing",
                          "processing-key",
                          request_hash,
                          now
                        )

               {:ok, :reserved}
             end)
  end
end
