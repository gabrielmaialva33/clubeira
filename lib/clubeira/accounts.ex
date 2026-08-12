defmodule Clubeira.Accounts do
  @moduledoc """
  Global user authentication and revocable API sessions.

  Raw bearer tokens are returned only when a session is created. The database
  stores a SHA-256 digest, so a database read cannot recover active tokens.
  """

  import Ecto.Query

  require Logger

  alias Clubeira.Accounts.EmailVerification
  alias Clubeira.Accounts.EmailVerificationSubmission
  alias Clubeira.Accounts.PasswordCredential
  alias Clubeira.Accounts.PasswordRecovery
  alias Clubeira.Accounts.PasswordResetCompletion
  alias Clubeira.Accounts.PasswordResetRequest
  alias Clubeira.Accounts.Registration
  alias Clubeira.Accounts.RequestContext
  alias Clubeira.Accounts.Scope
  alias Clubeira.Accounts.User
  alias Clubeira.Accounts.UserSession
  alias Clubeira.Audit
  alias Clubeira.Legal
  alias Clubeira.Repo
  alias Clubeira.Security.PasswordGate
  alias Clubeira.Tenancy.ActorScope

  @session_validity_seconds 30 * 24 * 60 * 60
  @token_bytes 32

  @type login_result :: %{
          token: String.t(),
          token_type: String.t(),
          expires_at: DateTime.t(),
          user: User.t()
        }

  @type registration_error ::
          Ecto.Changeset.t()
          | :legal_acceptance_invalid
          | :legal_documents_unavailable
          | :rate_limited

  @spec register(map()) :: {:ok, login_result()} | {:error, registration_error()}
  def register(attributes) when is_map(attributes) do
    register(attributes, RequestContext.new!())
  end

  def register(attributes), do: Registration.new(attributes)

  @doc false
  @spec change_registration(term()) :: Ecto.Changeset.t()
  def change_registration(attributes \\ %{}), do: Registration.change(attributes)

  @doc false
  @spec change_password_reset_request(term()) :: Ecto.Changeset.t()
  def change_password_reset_request(attributes \\ %{}),
    do: PasswordResetRequest.change(attributes)

  @doc false
  @spec change_password_reset(term()) :: Ecto.Changeset.t()
  def change_password_reset(attributes \\ %{}), do: PasswordResetCompletion.change(attributes)

  @doc false
  @spec change_email_verification(term()) :: Ecto.Changeset.t()
  def change_email_verification(attributes \\ %{}),
    do: EmailVerificationSubmission.change(attributes)

  @spec register(map(), RequestContext.t()) ::
          {:ok, login_result()} | {:error, registration_error()}
  def register(attributes, %RequestContext{} = context) when is_map(attributes) do
    with {:ok, registration} <- Registration.new(attributes),
         :ok <-
           Legal.validate_registration_acceptances(
             Repo,
             registration.legal_document_version_ids,
             "pt-BR"
           ),
         {:ok, password_hash} <- hash_password(registration.password) do
      registration
      |> persist_registration(password_hash, context)
      |> request_registration_email_verification(context)
    end
  end

  def register(attributes, %RequestContext{}), do: Registration.new(attributes)

  @spec login(String.t(), String.t()) ::
          {:ok, login_result()} | {:error, :invalid_credentials | :rate_limited}
  def login(email, password) when is_binary(email) and is_binary(password) do
    login(email, password, RequestContext.new!())
  end

  def login(_email, _password), do: invalid_credentials()

  @spec login(String.t(), String.t(), RequestContext.t()) ::
          {:ok, login_result()} | {:error, :invalid_credentials | :rate_limited}
  def login(email, password, %RequestContext{} = context)
      when is_binary(email) and is_binary(password) do
    normalized_email = String.trim(email)

    if valid_login_input?(normalized_email, password) do
      case verify_credentials(normalized_email, password) do
        {:ok, user} -> create_session(user, context)
        {:error, :invalid_credentials} -> deny_login()
        {:error, :capacity_exhausted} -> {:error, :rate_limited}
      end
    else
      invalid_credentials()
    end
  end

  def login(_email, _password, %RequestContext{}), do: invalid_credentials()

  @doc """
  Requests a password reset without revealing whether the email is registered.
  """
  @spec request_password_reset(String.t(), RequestContext.t()) :: :ok | {:error, term()}
  defdelegate request_password_reset(email, context), to: PasswordRecovery, as: :request

  @doc """
  Resets a password through a valid single-use recovery credential.
  """
  @spec reset_password(String.t(), term(), RequestContext.t()) ::
          :ok | {:error, PasswordRecovery.reset_error()}
  defdelegate reset_password(token, password, context), to: PasswordRecovery, as: :reset

  @doc """
  Issues a new email ownership proof for an authenticated, unverified account.
  """
  @spec request_email_verification(User.t(), RequestContext.t()) :: :ok | {:error, term()}
  defdelegate request_email_verification(user, context), to: EmailVerification, as: :request

  @doc """
  Confirms email ownership through an opaque, single-use credential.
  """
  @spec verify_email(String.t(), RequestContext.t()) ::
          :ok | {:error, EmailVerification.verification_error()}
  defdelegate verify_email(token, context), to: EmailVerification, as: :verify

  @spec set_password(User.t(), String.t()) ::
          {:ok, PasswordCredential.t()} | {:error, Ecto.Changeset.t() | :rate_limited}
  def set_password(%User{} = user, password) do
    set_password(user, password, RequestContext.new!())
  end

  @spec set_password(User.t(), String.t(), RequestContext.t()) ::
          {:ok, PasswordCredential.t()} | {:error, Ecto.Changeset.t() | :rate_limited}
  def set_password(%User{} = user, password, %RequestContext{} = context) do
    with {:ok, validated_password} <- PasswordCredential.validate_password(password),
         {:ok, password_hash} <- hash_password(validated_password) do
      changeset =
        PasswordCredential.hashed_changeset(user, password_hash, DateTime.utc_now(:microsecond))

      Repo.transact(fn repo -> persist_password(repo, changeset, user, context) end)
    end
  end

  @spec fetch_scope_by_api_token(String.t()) :: {:ok, Scope.t()} | :error
  def fetch_scope_by_api_token(token) when is_binary(token) and byte_size(token) <= 128 do
    fetch_scope_by_api_token(token, RequestContext.new!())
  end

  def fetch_scope_by_api_token(_token), do: :error

  @spec fetch_scope_by_api_token(String.t(), RequestContext.t()) :: {:ok, Scope.t()} | :error
  def fetch_scope_by_api_token(token, %RequestContext{} = context)
      when is_binary(token) and byte_size(token) <= 128 do
    with {:ok, decoded_token} <- Base.url_decode64(token, padding: false),
         true <- byte_size(decoded_token) == @token_bytes,
         %UserSession{} = session <- fetch_active_session(hash_token(decoded_token)) do
      {:ok, Scope.for_session(session.user, session, context)}
    else
      _invalid -> :error
    end
  end

  def fetch_scope_by_api_token(_token, %RequestContext{}), do: :error

  @doc """
  Revalidates a trusted account scope against the persisted session and user.

  Long-lived transports must call this before privileged mutations so session
  revocation, expiration and user disablement take effect without a remount.
  """
  @spec refresh_scope(Scope.t()) :: {:ok, Scope.t()} | :error
  def refresh_scope(%Scope{} = scope) do
    case fetch_active_session(scope.session_id, scope.user.id) do
      %UserSession{} = session ->
        {:ok, Scope.for_session(session.user, session, RequestContext.new!())}

      nil ->
        :error
    end
  end

  def refresh_scope(_scope), do: :error

  @spec revoke_session(Scope.t()) :: :ok
  def revoke_session(%Scope{} = scope) do
    context = RequestContext.new!(scope.request_id)

    {:ok, :ok} =
      Repo.transact(fn repo ->
        now = DateTime.utc_now(:microsecond)

        {revoked_count, _sessions} =
          repo.update_all(
            from(session in UserSession,
              where:
                session.id == ^scope.session_id and
                  session.user_id == ^scope.user.id and
                  is_nil(session.revoked_at)
            ),
            set: [revoked_at: now]
          )

        if revoked_count == 1 do
          Audit.record_system!(repo, context, %{
            actor_user_id: scope.user.id,
            action: "authentication.session.revoked",
            resource_type: "user_session",
            resource_id: scope.session_id,
            occurred_at: now
          })
        end

        {:ok, :ok}
      end)

    :ok
  end

  @doc """
  Deletes sessions whose expiration or revocation predates the retention cutoff.
  """
  @spec purge_stale_sessions(DateTime.t()) :: non_neg_integer()
  def purge_stale_sessions(%DateTime{} = retention_cutoff) do
    {deleted_count, _sessions} =
      Repo.delete_all(
        from(session in UserSession,
          where:
            session.expires_at < ^retention_cutoff or
              (not is_nil(session.revoked_at) and session.revoked_at < ^retention_cutoff)
        )
      )

    deleted_count
  end

  defp verify_credentials(email, password) do
    result =
      Repo.one(
        from(user in User,
          left_join: credential in PasswordCredential,
          on: credential.user_id == user.id,
          where: user.email == ^email,
          select: {user, credential.password_hash}
        )
      )

    PasswordGate.run(fn -> verify_password(result, password) end)
  end

  defp persist_password(repo, changeset, user, context) do
    with {:ok, credential} <-
           repo.insert(changeset,
             conflict_target: [:user_id],
             on_conflict: {:replace, [:password_hash, :password_changed_at, :updated_at]},
             returning: true
           ) do
      now = DateTime.utc_now(:microsecond)

      repo.update_all(
        from(session in UserSession,
          where: session.user_id == ^user.id and is_nil(session.revoked_at)
        ),
        set: [revoked_at: now]
      )

      Audit.record_system!(repo, context, %{
        actor_user_id: user.id,
        action: "authentication.password.changed",
        resource_type: "user",
        resource_id: user.id,
        occurred_at: now
      })

      {:ok, credential}
    end
  end

  defp verify_password({%User{} = user, password_hash}, password)
       when is_binary(password_hash) do
    password_valid? = Argon2.verify_pass(password, password_hash)

    if password_valid? and active?(user) do
      {:ok, user}
    else
      {:error, :invalid_credentials}
    end
  end

  defp verify_password(_missing, _password) do
    Argon2.no_user_verify()
    {:error, :invalid_credentials}
  end

  defp create_session(%User{} = user, %RequestContext{} = context) do
    session_material = new_session_material()

    transaction_result =
      Repo.transact(fn repo ->
        persist_session(
          repo,
          user.id,
          session_material.token_hash,
          session_material.now,
          session_material.expires_at,
          context
        )
      end)

    format_session_result(transaction_result, session_material.token)
  end

  defp persist_registration(registration, password_hash, context) do
    session_material = new_session_material()

    transaction_result =
      Repo.transact(fn repo ->
        with :ok <-
               Legal.validate_registration_acceptances(
                 repo,
                 registration.legal_document_version_ids,
                 "pt-BR"
               ),
             {:ok, user} <- repo.insert(User.registration_changeset(registration.email)),
             {:ok, _credential} <-
               repo.insert(
                 PasswordCredential.registration_changeset(
                   user,
                   password_hash,
                   session_material.now
                 )
               ) do
          persist_registered_user(
            repo,
            registration,
            user,
            session_material,
            context
          )
        end
      end)

    format_session_result(transaction_result, session_material.token)
  end

  defp persist_registered_user(repo, registration, user, session_material, context) do
    actor_scope = ActorScope.new!(user.id, context.request_id)

    {:ok, :ok} =
      Repo.transact_as_actor(actor_scope, fn ->
        Legal.accept_registration!(
          repo,
          user,
          registration.legal_document_version_ids,
          session_material.now
        )

        {:ok, :ok}
      end)

    Audit.record_system!(repo, context, %{
      actor_user_id: user.id,
      action: "account.registered",
      resource_type: "user",
      resource_id: user.id,
      occurred_at: session_material.now
    })

    persist_session(
      repo,
      user.id,
      session_material.token_hash,
      session_material.now,
      session_material.expires_at,
      context
    )
  end

  defp format_session_result(transaction_result, encoded_token) do
    case transaction_result do
      {:ok, %{session: session, user: active_user}} ->
        {:ok,
         %{
           token: encoded_token,
           token_type: "Bearer",
           expires_at: session.expires_at,
           user: active_user
         }}

      {:error, :invalid_credentials} ->
        invalid_credentials()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_registration_email_verification(
         {:ok, %{user: %User{} = user}} = registration_result,
         context
       ) do
    case EmailVerification.request(user, context) do
      :ok ->
        registration_result

      {:error, reason} ->
        report_registration_verification_failure(user.id, reason)
        registration_result
    end
  rescue
    error ->
      report_registration_verification_failure(user.id, error)
      registration_result
  end

  defp request_registration_email_verification(registration_result, _context),
    do: registration_result

  defp report_registration_verification_failure(user_id, reason) do
    :telemetry.execute(
      [:clubeira, :accounts, :registration_email_verification_failed],
      %{count: 1},
      %{user_id: user_id}
    )

    Logger.error(
      "email verification issuance after registration failed user_id=#{user_id} reason=#{inspect(reason)}"
    )
  end

  defp new_session_material do
    decoded_token = :crypto.strong_rand_bytes(@token_bytes)
    now = DateTime.utc_now(:microsecond)

    %{
      token: Base.url_encode64(decoded_token, padding: false),
      token_hash: hash_token(decoded_token),
      now: now,
      expires_at: DateTime.add(now, @session_validity_seconds, :second)
    }
  end

  defp hash_password(password) do
    case PasswordGate.run(fn -> Argon2.hash_pwd_salt(password) end) do
      {:error, :capacity_exhausted} -> {:error, :rate_limited}
      password_hash when is_binary(password_hash) -> {:ok, password_hash}
    end
  end

  defp persist_session(repo, user_id, token_hash, now, expires_at, context) do
    case lock_active_user(repo, user_id) do
      %User{} = active_user ->
        repo.update_all(
          from(candidate in User, where: candidate.id == ^active_user.id),
          set: [authenticated_at: now, updated_at: now]
        )

        with {:ok, session} <-
               active_user
               |> UserSession.changeset(token_hash, expires_at)
               |> repo.insert() do
          Audit.record_system!(repo, context, %{
            actor_user_id: active_user.id,
            action: "authentication.session.created",
            resource_type: "user_session",
            resource_id: session.id,
            occurred_at: now
          })

          {:ok, %{session: session, user: %{active_user | authenticated_at: now}}}
        end

      nil ->
        {:error, :invalid_credentials}
    end
  end

  defp lock_active_user(repo, user_id) do
    repo.one(
      from(candidate in User,
        where:
          candidate.id == ^user_id and
            candidate.status == "active" and
            is_nil(candidate.disabled_at),
        lock: "FOR UPDATE"
      )
    )
  end

  defp fetch_active_session(token_hash) do
    Repo.one(
      from(session in UserSession,
        join: user in assoc(session, :user),
        where:
          session.token_hash == ^token_hash and
            is_nil(session.revoked_at) and
            session.expires_at > fragment("statement_timestamp()") and
            user.status == "active" and
            is_nil(user.disabled_at),
        preload: [user: user]
      )
    )
  end

  defp fetch_active_session(session_id, user_id) do
    Repo.one(
      from(session in UserSession,
        join: user in assoc(session, :user),
        where:
          session.id == ^session_id and
            session.user_id == ^user_id and
            is_nil(session.revoked_at) and
            session.expires_at > fragment("statement_timestamp()") and
            user.status == "active" and
            is_nil(user.disabled_at),
        preload: [user: user]
      )
    )
  end

  defp valid_login_input?(email, password) do
    trimmed_email = String.trim(email)

    trimmed_email != "" and byte_size(trimmed_email) <= 320 and
      byte_size(password) in 1..1024
  end

  defp active?(%User{status: "active", disabled_at: nil}), do: true
  defp active?(%User{}), do: false

  defp hash_token(decoded_token), do: :crypto.hash(:sha256, decoded_token)

  defp deny_login do
    :telemetry.execute([:clubeira, :security, :login_denied], %{count: 1}, %{})

    invalid_credentials()
  end

  defp invalid_credentials, do: {:error, :invalid_credentials}
end
