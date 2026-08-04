defmodule Clubeira.Accounts do
  @moduledoc """
  Global user authentication and revocable API sessions.

  Raw bearer tokens are returned only when a session is created. The database
  stores a SHA-256 digest, so a database read cannot recover active tokens.
  """

  import Ecto.Query

  alias Clubeira.Accounts.PasswordCredential
  alias Clubeira.Accounts.Scope
  alias Clubeira.Accounts.User
  alias Clubeira.Accounts.UserSession
  alias Clubeira.Repo

  @session_validity_seconds 30 * 24 * 60 * 60
  @token_bytes 32

  @type login_result :: %{
          token: String.t(),
          token_type: String.t(),
          expires_at: DateTime.t(),
          user: User.t()
        }

  @spec login(String.t(), String.t()) ::
          {:ok, login_result()} | {:error, :invalid_credentials}
  def login(email, password) when is_binary(email) and is_binary(password) do
    with true <- valid_login_input?(email, password),
         {:ok, user} <- verify_credentials(String.trim(email), password) do
      create_session(user)
    else
      _invalid -> invalid_credentials()
    end
  end

  def login(_email, _password), do: invalid_credentials()

  @spec set_password(User.t(), String.t()) ::
          {:ok, PasswordCredential.t()} | {:error, Ecto.Changeset.t()}
  def set_password(%User{} = user, password) do
    changeset = PasswordCredential.changeset(user, password)

    if changeset.valid? do
      Repo.transact(fn repo ->
        {:ok, credential} =
          repo.insert(changeset,
            conflict_target: [:user_id],
            on_conflict: {:replace, [:password_hash, :password_changed_at, :updated_at]},
            returning: true
          )

        repo.update_all(
          from(session in UserSession,
            where: session.user_id == ^user.id and is_nil(session.revoked_at)
          ),
          set: [revoked_at: DateTime.utc_now(:microsecond)]
        )

        {:ok, credential}
      end)
    else
      {:error, changeset}
    end
  end

  @spec fetch_scope_by_api_token(String.t()) :: {:ok, Scope.t()} | :error
  def fetch_scope_by_api_token(token) when is_binary(token) and byte_size(token) <= 128 do
    with {:ok, decoded_token} <- Base.url_decode64(token, padding: false),
         true <- byte_size(decoded_token) == @token_bytes,
         %UserSession{} = session <- fetch_active_session(hash_token(decoded_token)) do
      {:ok, Scope.for_session(session.user, session)}
    else
      _invalid -> :error
    end
  end

  def fetch_scope_by_api_token(_token), do: :error

  @spec revoke_session(Scope.t()) :: :ok
  def revoke_session(%Scope{} = scope) do
    Repo.update_all(
      from(session in UserSession,
        where:
          session.id == ^scope.session_id and
            session.user_id == ^scope.user.id and
            is_nil(session.revoked_at)
      ),
      set: [revoked_at: DateTime.utc_now(:microsecond)]
    )

    :ok
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

    case result do
      {%User{} = user, password_hash} when is_binary(password_hash) ->
        password_valid? = Argon2.verify_pass(password, password_hash)

        if password_valid? and active?(user) do
          {:ok, user}
        else
          {:error, :invalid_credentials}
        end

      _missing ->
        Argon2.no_user_verify()
        {:error, :invalid_credentials}
    end
  end

  defp create_session(%User{} = user) do
    decoded_token = :crypto.strong_rand_bytes(@token_bytes)
    encoded_token = Base.url_encode64(decoded_token, padding: false)
    now = DateTime.utc_now(:microsecond)
    expires_at = DateTime.add(now, @session_validity_seconds, :second)

    transaction_result =
      Repo.transact(fn repo ->
        persist_session(repo, user.id, hash_token(decoded_token), now, expires_at)
      end)

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
    end
  end

  defp persist_session(repo, user_id, token_hash, now, expires_at) do
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

  defp valid_login_input?(email, password) do
    trimmed_email = String.trim(email)

    trimmed_email != "" and byte_size(trimmed_email) <= 320 and
      byte_size(password) in 1..1024
  end

  defp active?(%User{status: "active", disabled_at: nil}), do: true
  defp active?(%User{}), do: false

  defp hash_token(decoded_token), do: :crypto.hash(:sha256, decoded_token)

  defp invalid_credentials, do: {:error, :invalid_credentials}
end
