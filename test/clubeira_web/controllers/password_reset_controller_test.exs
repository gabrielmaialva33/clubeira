defmodule ClubeiraWeb.PasswordResetControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  import Ecto.Query
  import Swoosh.TestAssertions

  alias Clubeira.Accounts.PasswordResetToken
  alias Clubeira.Audit.SystemEvent
  alias Clubeira.Factory
  alias Clubeira.Repo

  @old_password "uma-senha-antiga-bem-forte"
  @new_password "uma-senha-nova-ainda-mais-forte"

  setup :set_swoosh_global

  test "requesting a reset stores only a token digest and sends the raw token by email", %{
    conn: conn
  } do
    user = Factory.insert(:user, email: "member@example.test")

    conn =
      post(conn, ~p"/api/v1/auth/password-reset-requests", %{
        "email" => "  MEMBER@Example.Test "
      })

    assert response(conn, :accepted) == ""
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]

    assert_email_sent(fn email ->
      assert Enum.any?(email.to, &match?({_name, "member@example.test"}, &1))
      assert email.subject == "Redefina sua senha do Clubeira"
      assert [_, token] = Regex.run(~r/[?&]token=([A-Za-z0-9_-]{43})/, email.text_body)
      send(self(), {:password_reset_token, token})
      true
    end)

    assert_receive {:password_reset_token, token}
    decoded_token = Base.url_decode64!(token, padding: false)

    assert %{rows: [[reset_id, token_hash, expires_at, nil, nil]]} =
             Repo.query!(
               """
               SELECT id::text, token_hash, expires_at, consumed_at, revoked_at
               FROM user_password_reset_tokens
               WHERE user_id = $1
               """,
               [Ecto.UUID.dump!(user.id)]
             )

    assert token_hash == :crypto.hash(:sha256, decoded_token)
    assert DateTime.after?(expires_at, DateTime.utc_now())
    refute token_hash == token

    assert %SystemEvent{
             actor_user_id: nil,
             actor_kind: "system",
             action: "authentication.password_reset.requested",
             resource_type: "user_password_reset_token",
             resource_id: ^reset_id
           } = Repo.get_by!(SystemEvent, request_id: conn.assigns.request_id)
  end

  test "consuming a reset changes the password and revokes sessions atomically", %{conn: conn} do
    user = Factory.insert(:user, email: "reset@example.test")
    assert {:ok, _credential} = Clubeira.Accounts.set_password(user, @old_password)
    assert {:ok, session} = Clubeira.Accounts.login(user.email, @old_password)

    request_conn =
      post(conn, ~p"/api/v1/auth/password-reset-requests", %{"email" => user.email})

    assert response(request_conn, :accepted) == ""

    assert_email_sent(fn email ->
      assert [_, token] = Regex.run(~r/[?&]token=([A-Za-z0-9_-]{43})/, email.text_body)
      send(self(), {:password_reset_token, token})
      true
    end)

    assert_receive {:password_reset_token, token}

    reset_conn =
      request_conn
      |> recycle()
      |> post(~p"/api/v1/auth/password-resets", %{
        "token" => token,
        "password" => @new_password
      })

    assert response(reset_conn, :no_content) == ""
    assert get_resp_header(reset_conn, "cache-control") == ["private, no-store"]
    assert :error = Clubeira.Accounts.fetch_scope_by_api_token(session.token)
    assert {:error, :invalid_credentials} = Clubeira.Accounts.login(user.email, @old_password)
    assert {:ok, _new_session} = Clubeira.Accounts.login(user.email, @new_password)

    assert %{rows: [[consumed_at]]} =
             Repo.query!(
               "SELECT consumed_at FROM user_password_reset_tokens WHERE user_id = $1",
               [Ecto.UUID.dump!(user.id)]
             )

    assert %DateTime{} = consumed_at

    assert %SystemEvent{
             actor_user_id: nil,
             actor_kind: "system",
             action: "authentication.password_reset.completed",
             resource_type: "user",
             resource_id: resource_id
           } = Repo.get_by!(SystemEvent, request_id: reset_conn.assigns.request_id)

    assert resource_id == user.id
  end

  test "reset requests do not disclose unknown, disabled, or malformed accounts", %{conn: conn} do
    Factory.insert(:user,
      email: "disabled@example.test",
      disabled_at: DateTime.utc_now(:microsecond)
    )

    for params <- [
          %{"email" => "unknown@example.test"},
          %{"email" => "disabled@example.test"},
          %{"email" => String.duplicate("x", 321)},
          %{}
        ] do
      response_conn =
        conn
        |> recycle()
        |> post(~p"/api/v1/auth/password-reset-requests", params)

      assert response(response_conn, :accepted) == ""
      assert get_resp_header(response_conn, "cache-control") == ["private, no-store"]
    end

    refute_email_sent()
    assert Repo.aggregate("user_password_reset_tokens", :count) == 0

    refute Repo.exists?(
             from(event in SystemEvent,
               where: event.action == "authentication.password_reset.requested"
             )
           )
  end

  test "invalid passwords do not burn the token and a consumed token cannot be replayed", %{
    conn: conn
  } do
    user = Factory.insert(:user, email: "single-use@example.test")
    assert {:ok, _credential} = Clubeira.Accounts.set_password(user, @old_password)

    request_conn =
      post(conn, ~p"/api/v1/auth/password-reset-requests", %{"email" => user.email})

    assert response(request_conn, :accepted) == ""
    token = receive_reset_token()

    assert request_conn
           |> recycle()
           |> post(~p"/api/v1/auth/password-resets", %{
             "token" => token,
             "password" => "curta"
           })
           |> json_response(:unprocessable_entity) == %{
             "errors" => %{"detail" => "Unprocessable Content"}
           }

    assert %{rows: [[nil]]} =
             Repo.query!(
               "SELECT consumed_at FROM user_password_reset_tokens WHERE user_id = $1",
               [Ecto.UUID.dump!(user.id)]
             )

    assert request_conn
           |> recycle()
           |> post(~p"/api/v1/auth/password-resets", %{
             "token" => token,
             "password" => @new_password
           })
           |> response(:no_content) == ""

    replay_password = "senha-de-replay-que-nao-deve-entrar"

    assert request_conn
           |> recycle()
           |> post(~p"/api/v1/auth/password-resets", %{
             "token" => token,
             "password" => replay_password
           })
           |> json_response(:unprocessable_entity) == %{
             "errors" => %{"detail" => "Unprocessable Content"}
           }

    assert {:ok, _session} = Clubeira.Accounts.login(user.email, @new_password)
    assert {:error, :invalid_credentials} = Clubeira.Accounts.login(user.email, replay_password)

    assert Repo.aggregate(
             from(event in SystemEvent,
               where:
                 event.action == "authentication.password_reset.completed" and
                   event.resource_id == ^user.id
             ),
             :count
           ) == 1
  end

  test "an expired token cannot change credentials or revoke sessions", %{conn: conn} do
    user = Factory.insert(:user, email: "expired@example.test")
    assert {:ok, _credential} = Clubeira.Accounts.set_password(user, @old_password)
    assert {:ok, session} = Clubeira.Accounts.login(user.email, @old_password)

    request_conn =
      post(conn, ~p"/api/v1/auth/password-reset-requests", %{"email" => user.email})

    assert response(request_conn, :accepted) == ""
    token = receive_reset_token()
    now = DateTime.utc_now(:microsecond)

    Repo.update_all(
      from(reset in PasswordResetToken, where: reset.user_id == ^user.id),
      set: [inserted_at: DateTime.add(now, -3_600), expires_at: DateTime.add(now, -1)]
    )

    assert request_conn
           |> recycle()
           |> post(~p"/api/v1/auth/password-resets", %{
             "token" => token,
             "password" => @new_password
           })
           |> json_response(:unprocessable_entity) == %{
             "errors" => %{"detail" => "Unprocessable Content"}
           }

    assert {:ok, _scope} = Clubeira.Accounts.fetch_scope_by_api_token(session.token)
    assert {:ok, _new_session} = Clubeira.Accounts.login(user.email, @old_password)
    assert {:error, :invalid_credentials} = Clubeira.Accounts.login(user.email, @new_password)
  end

  test "a new request revokes the previous token before issuing another", %{conn: conn} do
    user = Factory.insert(:user, email: "superseded@example.test")
    assert {:ok, _credential} = Clubeira.Accounts.set_password(user, @old_password)

    first_request =
      post(conn, ~p"/api/v1/auth/password-reset-requests", %{"email" => user.email})

    assert response(first_request, :accepted) == ""
    first_token = receive_reset_token()

    second_request =
      first_request
      |> recycle()
      |> post(~p"/api/v1/auth/password-reset-requests", %{"email" => user.email})

    assert response(second_request, :accepted) == ""
    second_token = receive_reset_token()
    refute first_token == second_token

    assert [first_reset, second_reset] =
             Repo.all(
               from(reset in PasswordResetToken,
                 where: reset.user_id == ^user.id,
                 order_by: [asc: reset.inserted_at, asc: reset.id]
               )
             )

    assert %DateTime{} = first_reset.revoked_at
    assert second_reset.revoked_at == nil

    assert second_request
           |> recycle()
           |> post(~p"/api/v1/auth/password-resets", %{
             "token" => first_token,
             "password" => @new_password
           })
           |> json_response(:unprocessable_entity) == %{
             "errors" => %{"detail" => "Unprocessable Content"}
           }

    assert second_request
           |> recycle()
           |> post(~p"/api/v1/auth/password-resets", %{
             "token" => second_token,
             "password" => @new_password
           })
           |> response(:no_content) == ""
  end

  defp receive_reset_token do
    assert_email_sent(fn email ->
      assert [_, token] = Regex.run(~r/[?&]token=([A-Za-z0-9_-]{43})/, email.text_body)
      send(self(), {:password_reset_token, token})
      true
    end)

    assert_receive {:password_reset_token, token}
    token
  end
end
