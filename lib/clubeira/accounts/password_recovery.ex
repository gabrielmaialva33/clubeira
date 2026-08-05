defmodule Clubeira.Accounts.PasswordRecovery do
  @moduledoc """
  Issues and consumes short-lived password reset credentials.

  Public request responses never reveal whether an email belongs to an active
  account. Raw reset tokens leave this boundary only through email.
  """

  import Ecto.Query

  require Logger

  alias Clubeira.Accounts.PasswordResetEmail
  alias Clubeira.Accounts.PasswordResetToken
  alias Clubeira.Accounts.RequestContext
  alias Clubeira.Accounts.User
  alias Clubeira.Audit
  alias Clubeira.Mailer
  alias Clubeira.Repo

  @token_bytes 32

  @spec request(String.t(), RequestContext.t()) :: :ok | {:error, term()}
  def request(email, %RequestContext{} = context) when is_binary(email) do
    token = new_token()

    case persist_request(normalize_email(email), token, context) do
      {:ok, :ignored} ->
        :ok

      {:ok, {reset, recipient}} ->
        deliver(reset, recipient, token)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def request(_email, %RequestContext{}), do: :ok

  defp persist_request(email, token, context) do
    Repo.transact(fn repo ->
      case lock_active_user(repo, email) do
        nil -> {:ok, :ignored}
        %User{} = user -> issue_for_user(repo, user, token, context)
      end
    end)
  end

  defp issue_for_user(repo, user, token, context) do
    now = database_now(repo)
    expires_at = DateTime.add(now, Keyword.fetch!(config!(), :token_ttl_seconds), :second)

    repo.update_all(
      from(candidate in PasswordResetToken,
        where:
          candidate.user_id == ^user.id and is_nil(candidate.consumed_at) and
            is_nil(candidate.revoked_at)
      ),
      set: [revoked_at: now]
    )

    with {:ok, reset} <-
           user
           |> PasswordResetToken.changeset(hash_token(token), expires_at, now)
           |> repo.insert() do
      Audit.record_system!(repo, context, %{
        action: "authentication.password_reset.requested",
        resource_type: "user_password_reset_token",
        resource_id: reset.id,
        occurred_at: now
      })

      {:ok, {reset, user.email}}
    end
  end

  defp deliver(reset, recipient, token) do
    email = PasswordResetEmail.build(recipient, token, config!())

    case Mailer.deliver(email) do
      {:ok, _metadata} -> :ok
      {:error, _reason} -> handle_delivery_failure(reset)
    end
  rescue
    _error -> handle_delivery_failure(reset)
  end

  defp handle_delivery_failure(reset) do
    now = DateTime.utc_now(:microsecond)

    Repo.update_all(
      from(candidate in PasswordResetToken,
        where:
          candidate.id == ^reset.id and is_nil(candidate.consumed_at) and
            is_nil(candidate.revoked_at)
      ),
      set: [revoked_at: now]
    )

    :telemetry.execute(
      [:clubeira, :accounts, :password_reset_delivery_failed],
      %{count: 1},
      %{password_reset_token_id: reset.id}
    )

    Logger.error("password reset email delivery failed token_id=#{reset.id}")
    :ok
  end

  defp lock_active_user(repo, email) do
    repo.one(
      from(user in User,
        where: user.email == ^email and user.status == "active" and is_nil(user.disabled_at),
        lock: "FOR UPDATE"
      )
    )
  end

  defp database_now(repo) do
    %{rows: [[now]]} = repo.query!("SELECT statement_timestamp()")
    now
  end

  defp new_token do
    @token_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp hash_token(token) do
    token
    |> Base.url_decode64!(padding: false)
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp normalize_email(email) do
    normalized = email |> String.trim() |> String.downcase()

    if byte_size(normalized) <= 320, do: normalized, else: ""
  end

  defp config!, do: Application.fetch_env!(:clubeira, __MODULE__)
end
