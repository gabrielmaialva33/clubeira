defmodule Clubeira.Accounts.PasswordRecoveryTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Accounts.PasswordRecovery
  alias Clubeira.Accounts.PasswordResetToken

  test "purges only terminal reset credentials beyond the retention cutoff" do
    user = insert(:user)
    now = DateTime.utc_now(:microsecond)

    stale =
      insert_reset!(
        user,
        :crypto.strong_rand_bytes(32),
        DateTime.add(now, -3 * 24 * 60 * 60),
        DateTime.add(now, -2 * 24 * 60 * 60)
      )

    retained =
      insert_reset!(
        insert(:user),
        :crypto.strong_rand_bytes(32),
        now,
        DateTime.add(now, 30 * 60)
      )

    assert PasswordRecovery.purge_stale_tokens(DateTime.add(now, -24 * 60 * 60)) == 1
    assert Repo.get(PasswordResetToken, stale.id) == nil
    assert %PasswordResetToken{} = Repo.get(PasswordResetToken, retained.id)
  end

  defp insert_reset!(user, token_hash, inserted_at, expires_at) do
    user
    |> PasswordResetToken.changeset(token_hash, expires_at, inserted_at)
    |> Repo.insert!()
  end
end
