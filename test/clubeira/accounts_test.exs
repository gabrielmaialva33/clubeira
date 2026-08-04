defmodule Clubeira.AccountsTest do
  use Clubeira.DataCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Accounts.PasswordCredential
  alias Clubeira.Accounts.RequestContext
  alias Clubeira.Accounts.User
  alias Clubeira.Accounts.UserSession
  alias Clubeira.Audit.SystemEvent
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

  test "disabling a user invalidates an already issued token", %{user: user} do
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)

    Repo.update_all(from(candidate in User, where: candidate.id == ^user.id),
      set: [disabled_at: DateTime.utc_now(:microsecond)]
    )

    assert :error = Accounts.fetch_scope_by_api_token(session.token)
  end

  test "authentication lifecycle writes correlated global audit events", %{user: user} do
    login_request_id = Ecto.UUID.generate(version: 7)
    login_context = RequestContext.new!(login_request_id)

    assert {:ok, _credential} = Accounts.set_password(user, @password, login_context)
    assert {:ok, session} = Accounts.login(user.email, @password, login_context)

    revoke_request_id = Ecto.UUID.generate(version: 7)
    revoke_context = RequestContext.new!(revoke_request_id)
    assert {:ok, scope} = Accounts.fetch_scope_by_api_token(session.token, revoke_context)
    assert :ok = Accounts.revoke_session(scope)

    created =
      Repo.get_by!(SystemEvent,
        action: "authentication.session.created",
        request_id: login_request_id
      )

    assert created.actor_user_id == user.id
    assert created.resource_id == scope.session_id

    assert %SystemEvent{actor_user_id: actor_user_id} =
             Repo.get_by!(SystemEvent,
               action: "authentication.session.revoked",
               request_id: revoke_request_id
             )

    assert actor_user_id == user.id
  end

  test "a denied login emits telemetry without growing the immutable audit table" do
    handler_id = {__MODULE__, make_ref()}
    test_process = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:clubeira, :security, :login_denied],
        fn event, measurements, metadata, _config ->
          send(test_process, {:login_denied, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    request_id = Ecto.UUID.generate(version: 7)
    context = RequestContext.new!(request_id)

    assert Accounts.login("unknown@example.test", @password, context) ==
             {:error, :invalid_credentials}

    assert_receive {:login_denied, [:clubeira, :security, :login_denied], %{count: 1}, %{}}

    refute Repo.exists?(
             from(event in SystemEvent,
               where:
                 event.action == "authentication.login.denied" and
                   event.request_id == ^request_id
             )
           )
  end

  test "purges only sessions beyond the retention cutoff", %{user: user} do
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, stale} = Accounts.login(user.email, @password)
    assert {:ok, retained} = Accounts.login(user.email, @password)

    now = DateTime.utc_now(:microsecond)
    stale_session_id = token_session_id(stale.token)
    retained_session_id = token_session_id(retained.token)

    Repo.update_all(
      from(session in UserSession, where: session.id == ^stale_session_id),
      set: [inserted_at: DateTime.add(now, -3), expires_at: DateTime.add(now, -2)]
    )

    assert Accounts.purge_stale_sessions(DateTime.add(now, -1)) == 1
    assert Repo.get(UserSession, stale_session_id) == nil
    assert %UserSession{} = Repo.get(UserSession, retained_session_id)
  end

  defp token_session_id(token) do
    token_hash = token |> Base.url_decode64!(padding: false) |> then(&:crypto.hash(:sha256, &1))
    Repo.get_by!(UserSession, token_hash: token_hash).id
  end
end
