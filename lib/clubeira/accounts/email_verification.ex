defmodule Clubeira.Accounts.EmailVerification do
  @moduledoc """
  Issues and consumes short-lived proofs that an account owns its email address.

  Raw credentials leave this boundary only through email. Consuming the same
  credential again is an idempotent success after the first verification.
  """

  import Ecto.Query

  require Logger

  alias Clubeira.Accounts.EmailVerificationEmail
  alias Clubeira.Accounts.EmailVerificationToken
  alias Clubeira.Accounts.RequestContext
  alias Clubeira.Accounts.User
  alias Clubeira.Audit
  alias Clubeira.Mailer
  alias Clubeira.Repo

  @token_bytes 32

  @spec request(User.t(), RequestContext.t()) :: :ok | {:error, term()}
  def request(%User{} = user, %RequestContext{} = context) do
    token = new_token()

    case persist_request(user.id, token, context) do
      {:ok, :ignored} -> :ok
      {:ok, {verification, recipient}} -> deliver(verification, recipient, token)
      {:error, reason} -> {:error, reason}
    end
  end

  @type verification_error :: :invalid_email_verification

  @spec verify(String.t(), RequestContext.t()) :: :ok | {:error, verification_error()}
  def verify(token, %RequestContext{} = context)
      when is_binary(token) and byte_size(token) <= 128 do
    with {:ok, token_hash} <- decode_token(token),
         {:ok, user_id} <- fetch_token_user_id(token_hash) do
      consume(user_id, token_hash, context)
    end
  end

  def verify(_token, %RequestContext{}), do: {:error, :invalid_email_verification}

  @spec purge_stale_tokens(DateTime.t()) :: non_neg_integer()
  def purge_stale_tokens(%DateTime{} = retention_cutoff) do
    {deleted_count, _tokens} =
      Repo.delete_all(
        from(verification in EmailVerificationToken,
          where:
            verification.expires_at < ^retention_cutoff or
              (not is_nil(verification.consumed_at) and
                 verification.consumed_at < ^retention_cutoff) or
              (not is_nil(verification.revoked_at) and
                 verification.revoked_at < ^retention_cutoff)
        )
      )

    deleted_count
  end

  defp persist_request(user_id, token, context) do
    Repo.transact(fn repo ->
      case lock_active_user(repo, user_id) do
        %User{email_verified_at: nil} = user -> issue_for_user(repo, user, token, context)
        %User{} -> {:ok, :ignored}
        nil -> {:ok, :ignored}
      end
    end)
  end

  defp issue_for_user(repo, user, token, context) do
    now = database_now(repo)
    expires_at = DateTime.add(now, Keyword.fetch!(config!(), :token_ttl_seconds), :second)

    repo.update_all(
      from(candidate in EmailVerificationToken,
        where:
          candidate.user_id == ^user.id and is_nil(candidate.consumed_at) and
            is_nil(candidate.revoked_at)
      ),
      set: [revoked_at: now]
    )

    with {:ok, verification} <-
           user
           |> EmailVerificationToken.changeset(hash_token(token), expires_at, now)
           |> repo.insert() do
      Audit.record_system!(repo, context, %{
        actor_user_id: user.id,
        action: "account.email_verification.requested",
        resource_type: "user_email_verification_token",
        resource_id: verification.id,
        occurred_at: now
      })

      {:ok, {verification, user.email}}
    end
  end

  defp deliver(verification, recipient, token) do
    email = EmailVerificationEmail.build(recipient, token, config!())

    delivery_result =
      try do
        Mailer.deliver(email)
      rescue
        _error -> {:error, :delivery_exception}
      end

    case delivery_result do
      {:ok, _metadata} -> :ok
      {:error, _reason} -> handle_delivery_failure(verification)
    end
  end

  defp handle_delivery_failure(verification) do
    {:ok, :ok} =
      Repo.transact(fn repo ->
        now = database_now(repo)

        repo.update_all(
          from(candidate in EmailVerificationToken,
            where:
              candidate.id == ^verification.id and is_nil(candidate.consumed_at) and
                is_nil(candidate.revoked_at)
          ),
          set: [revoked_at: now]
        )

        {:ok, :ok}
      end)

    :telemetry.execute(
      [:clubeira, :accounts, :email_verification_delivery_failed],
      %{count: 1},
      %{email_verification_token_id: verification.id}
    )

    Logger.error("email verification delivery failed token_id=#{verification.id}")
    :ok
  end

  defp fetch_token_user_id(token_hash) do
    case Repo.one(
           from(verification in EmailVerificationToken,
             where: verification.token_hash == ^token_hash,
             select: verification.user_id
           )
         ) do
      user_id when is_binary(user_id) -> {:ok, user_id}
      nil -> {:error, :invalid_email_verification}
    end
  end

  defp consume(user_id, token_hash, context) do
    transaction = fn repo -> consume_locked(repo, user_id, token_hash, context) end

    case Repo.transact(transaction) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp consume_locked(repo, user_id, token_hash, context) do
    with %User{} = user <- lock_active_user(repo, user_id),
         %EmailVerificationToken{} = verification <-
           lock_verification(repo, user.id, token_hash) do
      verify_state(repo, user, verification, context)
    else
      nil -> {:error, :invalid_email_verification}
    end
  end

  defp verify_state(repo, user, verification, context) do
    now = database_now(repo)

    cond do
      not is_nil(verification.consumed_at) and not is_nil(user.email_verified_at) ->
        {:ok, :ok}

      not is_nil(verification.consumed_at) or not is_nil(verification.revoked_at) ->
        {:error, :invalid_email_verification}

      not DateTime.after?(verification.expires_at, now) ->
        {:error, :invalid_email_verification}

      not is_nil(user.email_verified_at) ->
        consume_without_audit(repo, verification, now)

      true ->
        persist_verification(repo, user, verification, context, now)
    end
  end

  defp consume_without_audit(repo, verification, now) do
    {1, _tokens} =
      repo.update_all(
        from(candidate in EmailVerificationToken, where: candidate.id == ^verification.id),
        set: [consumed_at: now]
      )

    {:ok, :ok}
  end

  defp persist_verification(repo, user, verification, context, now) do
    {1, _users} =
      repo.update_all(
        from(candidate in User, where: candidate.id == ^user.id),
        set: [email_verified_at: now, updated_at: now]
      )

    {1, _tokens} =
      repo.update_all(
        from(candidate in EmailVerificationToken, where: candidate.id == ^verification.id),
        set: [consumed_at: now]
      )

    Audit.record_system!(repo, context, %{
      actor_user_id: user.id,
      action: "account.email_verified",
      resource_type: "user",
      resource_id: user.id,
      occurred_at: now
    })

    {:ok, :ok}
  end

  defp lock_active_user(repo, user_id) do
    repo.one(
      from(user in User,
        where: user.id == ^user_id and user.status == "active" and is_nil(user.disabled_at),
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_verification(repo, user_id, token_hash) do
    repo.one(
      from(verification in EmailVerificationToken,
        where: verification.user_id == ^user_id and verification.token_hash == ^token_hash,
        lock: "FOR UPDATE"
      )
    )
  end

  defp database_now(repo) do
    %{rows: [[now]]} = repo.query!("SELECT transaction_timestamp()")
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
      _invalid -> {:error, :invalid_email_verification}
    end
  end

  defp hash_token(token) do
    token
    |> Base.url_decode64!(padding: false)
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp config!, do: Application.fetch_env!(:clubeira, __MODULE__)
end
