defmodule Clubeira.Accounts.EmailVerificationTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Accounts.EmailVerification
  alias Clubeira.Accounts.EmailVerificationToken

  test "purges only verification credentials beyond the retention cutoff" do
    now = DateTime.utc_now(:microsecond)

    stale =
      insert_verification!(
        insert(:user),
        DateTime.add(now, -3 * 24 * 60 * 60),
        DateTime.add(now, -2 * 24 * 60 * 60)
      )

    retained =
      insert_verification!(
        insert(:user),
        now,
        DateTime.add(now, 24 * 60 * 60)
      )

    assert EmailVerification.purge_stale_tokens(DateTime.add(now, -24 * 60 * 60)) == 1
    assert Repo.get(EmailVerificationToken, stale.id) == nil
    assert %EmailVerificationToken{} = Repo.get(EmailVerificationToken, retained.id)
  end

  defp insert_verification!(user, inserted_at, expires_at) do
    user
    |> EmailVerificationToken.changeset(:crypto.strong_rand_bytes(32), expires_at, inserted_at)
    |> Repo.insert!()
  end
end
