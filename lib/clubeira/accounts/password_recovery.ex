defmodule Clubeira.Accounts.PasswordRecovery do
  @moduledoc """
  Issues and consumes short-lived password reset credentials.

  Public request responses never reveal whether an email belongs to an active
  account. Raw reset tokens leave this boundary only through email.
  """

  import Ecto.Query

  require Logger

  alias Clubeira.Accounts.PasswordCredential
  alias Clubeira.Accounts.PasswordResetEmail
  alias Clubeira.Accounts.PasswordResetToken
  alias Clubeira.Accounts.RequestContext
  alias Clubeira.Accounts.User
  alias Clubeira.Accounts.UserSession
  alias Clubeira.Audit
  alias Clubeira.Mailer
  alias Clubeira.Repo
  alias Clubeira.Security.PasswordGate

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

  @type reset_error :: Ecto.Changeset.t() | :invalid_password_reset | :rate_limited

  @spec reset(String.t(), term(), RequestContext.t()) :: :ok | {:error, reset_error()}
  def reset(token, password, %RequestContext{} = context)
      when is_binary(token) and byte_size(token) <= 128 do
    with {:ok, token_hash} <- decode_token(token),
         {:ok, user} <- fetch_reset_user(token_hash),
         {:ok, validated_password} <- PasswordCredential.validate_password(password),
         {:ok, password_hash} <- hash_password(validated_password) do
      consume(user, token_hash, password_hash, context)
    end
  end

  def reset(_token, _password, %RequestContext{}), do: {:error, :invalid_password_reset}

  @doc """
  Deletes expired, consumed, or revoked reset credentials older than a cutoff.
  """
  @spec purge_stale_tokens(DateTime.t()) :: non_neg_integer()
  def purge_stale_tokens(%DateTime{} = retention_cutoff) do
    {deleted_count, _tokens} =
      Repo.delete_all(
        from(reset in PasswordResetToken,
          where:
            reset.expires_at < ^retention_cutoff or
              (not is_nil(reset.consumed_at) and reset.consumed_at < ^retention_cutoff) or
              (not is_nil(reset.revoked_at) and reset.revoked_at < ^retention_cutoff)
        )
      )

    deleted_count
  end

  defp persist_request(email, token, context) do
    Repo.transact(fn repo ->
      case lock_active_user_by_email(repo, email) do
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

    delivery_result =
      try do
        Mailer.deliver(email)
      rescue
        _error -> {:error, :delivery_exception}
      end

    case delivery_result do
      {:ok, _metadata} -> :ok
      {:error, _reason} -> handle_delivery_failure(reset)
    end
  end

  defp handle_delivery_failure(reset) do
    {:ok, :ok} =
      Repo.transact(fn repo ->
        now = database_now(repo)

        repo.update_all(
          from(candidate in PasswordResetToken,
            where:
              candidate.id == ^reset.id and is_nil(candidate.consumed_at) and
                is_nil(candidate.revoked_at)
          ),
          set: [revoked_at: now]
        )

        {:ok, :ok}
      end)

    :telemetry.execute(
      [:clubeira, :accounts, :password_reset_delivery_failed],
      %{count: 1},
      %{password_reset_token_id: reset.id}
    )

    Logger.error("password reset email delivery failed token_id=#{reset.id}")
    :ok
  end

  defp consume(user, token_hash, password_hash, context) do
    transaction = fn repo -> consume_locked(repo, user, token_hash, password_hash, context) end

    case Repo.transact(transaction) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp consume_locked(repo, user, token_hash, password_hash, context) do
    with %User{} = locked_user <- lock_active_user_by_id(repo, user.id),
         %PasswordResetToken{} = reset <- lock_reset(repo, locked_user.id, token_hash) do
      persist_reset(repo, locked_user, reset, password_hash, context)
    else
      nil -> {:error, :invalid_password_reset}
    end
  end

  defp persist_reset(repo, user, reset, password_hash, context) do
    now = database_now(repo)
    changeset = PasswordCredential.hashed_changeset(user, password_hash, now)

    with {:ok, _credential} <-
           repo.insert(changeset,
             conflict_target: [:user_id],
             on_conflict: {:replace, [:password_hash, :password_changed_at, :updated_at]},
             returning: true
           ) do
      {1, _tokens} =
        repo.update_all(
          from(candidate in PasswordResetToken, where: candidate.id == ^reset.id),
          set: [consumed_at: now]
        )

      repo.update_all(
        from(session in UserSession,
          where: session.user_id == ^user.id and is_nil(session.revoked_at)
        ),
        set: [revoked_at: now]
      )

      Audit.record_system!(repo, context, %{
        action: "authentication.password_reset.completed",
        resource_type: "user",
        resource_id: user.id,
        occurred_at: now
      })

      {:ok, :ok}
    end
  end

  defp fetch_reset_user(token_hash) do
    case Repo.one(
           from(reset in PasswordResetToken,
             join: user in assoc(reset, :user),
             where:
               reset.token_hash == ^token_hash and is_nil(reset.consumed_at) and
                 is_nil(reset.revoked_at) and
                 reset.expires_at > fragment("statement_timestamp()") and
                 user.status == "active" and is_nil(user.disabled_at),
             select: user
           )
         ) do
      %User{} = user -> {:ok, user}
      nil -> {:error, :invalid_password_reset}
    end
  end

  defp lock_active_user_by_email(repo, email) do
    repo.one(
      from(user in User,
        where: user.email == ^email and user.status == "active" and is_nil(user.disabled_at),
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_active_user_by_id(repo, user_id) do
    repo.one(
      from(user in User,
        where: user.id == ^user_id and user.status == "active" and is_nil(user.disabled_at),
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_reset(repo, user_id, token_hash) do
    repo.one(
      from(reset in PasswordResetToken,
        where:
          reset.user_id == ^user_id and reset.token_hash == ^token_hash and
            is_nil(reset.consumed_at) and is_nil(reset.revoked_at) and
            reset.expires_at > fragment("statement_timestamp()"),
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

  defp decode_token(token) do
    with {:ok, decoded_token} <- Base.url_decode64(token, padding: false),
         true <- byte_size(decoded_token) == @token_bytes do
      {:ok, :crypto.hash(:sha256, decoded_token)}
    else
      _invalid -> {:error, :invalid_password_reset}
    end
  end

  defp hash_password(password) do
    case PasswordGate.run(fn -> Argon2.hash_pwd_salt(password) end) do
      {:error, :capacity_exhausted} -> {:error, :rate_limited}
      password_hash when is_binary(password_hash) -> {:ok, password_hash}
    end
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
