defmodule Clubeira.Accounts.SessionJanitorTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Accounts.EmailVerificationToken
  alias Clubeira.Accounts.PasswordResetToken
  alias Clubeira.Accounts.SessionJanitor
  alias Clubeira.Accounts.UserSession

  test "purges every stale authentication credential and reports the cycle" do
    now = DateTime.utc_now(:microsecond)
    stale_inserted_at = DateTime.add(now, -3, :day)
    stale_expires_at = DateTime.add(now, -2, :day)

    session = insert_stale_session!(stale_inserted_at, stale_expires_at)
    reset = insert_reset_token!(stale_inserted_at, stale_expires_at)
    verification = insert_verification_token!(stale_inserted_at, stale_expires_at)

    attach_telemetry!()

    janitor =
      start_supervised!(
        {SessionJanitor,
         initial_delay_ms: 1, interval_ms: 60_000, retention_seconds: 24 * 60 * 60}
      )

    assert_receive {:janitor_telemetry, [:clubeira, :accounts, :sessions_purged], %{count: 1}}

    assert_receive {:janitor_telemetry, [:clubeira, :accounts, :password_reset_tokens_purged],
                    %{count: 1}}

    assert_receive {:janitor_telemetry, [:clubeira, :accounts, :email_verification_tokens_purged],
                    %{count: 1}}

    _state = :sys.get_state(janitor)

    assert Repo.get(UserSession, session.id) == nil
    assert Repo.get(PasswordResetToken, reset.id) == nil
    assert Repo.get(EmailVerificationToken, verification.id) == nil
  end

  defp attach_telemetry! do
    handler_id = "session-janitor-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    events = [
      [:clubeira, :accounts, :sessions_purged],
      [:clubeira, :accounts, :password_reset_tokens_purged],
      [:clubeira, :accounts, :email_verification_tokens_purged]
    ]

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, _metadata, pid ->
          send(pid, {:janitor_telemetry, event, measurements})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp insert_stale_session!(inserted_at, expires_at) do
    user = insert(:user)

    session =
      user
      |> UserSession.changeset(:crypto.strong_rand_bytes(32), DateTime.add(expires_at, 4, :day))
      |> Repo.insert!()

    {1, nil} =
      Repo.update_all(
        from(candidate in UserSession, where: candidate.id == ^session.id),
        set: [inserted_at: inserted_at, expires_at: expires_at]
      )

    session
  end

  defp insert_reset_token!(inserted_at, expires_at) do
    insert(:user)
    |> PasswordResetToken.changeset(:crypto.strong_rand_bytes(32), expires_at, inserted_at)
    |> Repo.insert!()
  end

  defp insert_verification_token!(inserted_at, expires_at) do
    insert(:user)
    |> EmailVerificationToken.changeset(:crypto.strong_rand_bytes(32), expires_at, inserted_at)
    |> Repo.insert!()
  end
end
