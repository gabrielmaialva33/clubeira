defmodule Clubeira.AccountsTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Accounts.PasswordCredential
  alias Clubeira.Accounts.User
  alias Clubeira.Accounts.UserSession
  alias Clubeira.RedemptionsFixtures

  @password "uma-senha-de-teste-forte"

  setup do
    fixture = RedemptionsFixtures.create!()
    user = Repo.get!(User, fixture.ids.user)

    %{fixture: fixture, user: user}
  end

  test "stores an Argon2 password hash and validates password length", %{user: user} do
    assert {:error, changeset} = Accounts.set_password(user, "curta")
    assert %{password: [message]} = errors_on(changeset)
    assert message =~ "should be at least 12"

    assert {:ok, credential} = Accounts.set_password(user, @password)
    assert credential.password_hash != @password
    assert Argon2.verify_pass(@password, credential.password_hash)

    persisted = Repo.get!(PasswordCredential, user.id)
    assert persisted.password_hash == credential.password_hash
  end

  test "issues only the raw bearer token and resolves it to a server scope", %{user: user} do
    assert {:ok, _credential} = Accounts.set_password(user, @password)

    assert {:ok, session} = Accounts.login("  #{String.upcase(user.email)} ", @password)
    assert session.token_type == "Bearer"
    assert byte_size(session.token) == 43

    persisted = Repo.get_by!(UserSession, user_id: user.id)
    refute persisted.token_hash == session.token

    decoded = Base.url_decode64!(session.token, padding: false)
    assert persisted.token_hash == :crypto.hash(:sha256, decoded)

    assert {:ok, scope} = Accounts.fetch_scope_by_api_token(session.token)
    assert scope.user.id == user.id
    assert scope.session_id == persisted.id
    assert Ecto.UUID.cast(scope.request_id) == {:ok, scope.request_id}
  end

  test "uses one generic error for unknown, incorrect, and disabled accounts", %{user: user} do
    assert {:ok, _credential} = Accounts.set_password(user, @password)

    assert Accounts.login(user.email, "senha-totalmente-errada") ==
             {:error, :invalid_credentials}

    assert Accounts.login("ninguem@example.test", @password) ==
             {:error, :invalid_credentials}

    Repo.update_all(from(candidate in User, where: candidate.id == ^user.id),
      set: [disabled_at: DateTime.utc_now(:microsecond)]
    )

    assert Accounts.login(user.email, @password) == {:error, :invalid_credentials}
  end

  test "revocation, expiration, and password rotation invalidate sessions", %{user: user} do
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, first} = Accounts.login(user.email, @password)
    assert {:ok, first_scope} = Accounts.fetch_scope_by_api_token(first.token)

    assert :ok = Accounts.revoke_session(first_scope)
    assert :error = Accounts.fetch_scope_by_api_token(first.token)

    assert {:ok, expiring} = Accounts.login(user.email, @password)

    now = DateTime.utc_now(:microsecond)

    Repo.update_all(
      from(session in UserSession, where: session.id == ^token_session_id(expiring.token)),
      set: [inserted_at: DateTime.add(now, -2), expires_at: DateTime.add(now, -1)]
    )

    assert :error = Accounts.fetch_scope_by_api_token(expiring.token)

    assert {:ok, rotating} = Accounts.login(user.email, @password)
    assert {:ok, _credential} = Accounts.set_password(user, "outra-senha-de-teste-forte")
    assert :error = Accounts.fetch_scope_by_api_token(rotating.token)
  end

  defp token_session_id(token) do
    token_hash = token |> Base.url_decode64!(padding: false) |> then(&:crypto.hash(:sha256, &1))
    Repo.get_by!(UserSession, token_hash: token_hash).id
  end
end
