defmodule ClubeiraWeb.Auth.BrowserSessionControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures

  @password "uma-senha-forte-para-o-painel"

  test "renders the backoffice login", %{conn: conn} do
    conn = get(conn, "/admin/login")
    response = html_response(conn, 200)

    assert response =~ ~s(id="backoffice-login-form")
    assert response =~ ~s(id="login-email")
    assert response =~ ~s(id="login-password")
    assert response =~ "Entre na sua operação"
    assert response =~ ~s(lang="pt-BR")
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
  end

  test "negotiates an English panel without changing machine-facing values", %{conn: conn} do
    response =
      conn
      |> put_req_header("accept-language", "en")
      |> get("/admin/login")
      |> html_response(200)

    assert response =~ "Sign in to your operation"
    assert response =~ ~s(lang="en")
  end

  test "starts an encrypted browser session for an administrator", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    user = authenticate_user!(admin_scope.actor_user_id)

    conn =
      post(conn, "/admin/login", %{
        "email" => user.email,
        "password" => @password
      })

    assert redirected_to(conn) == "/admin"

    token = get_session(conn, "backoffice_session_token")
    assert is_binary(token)
    refute conn |> get_resp_header("set-cookie") |> Enum.join(";") =~ token
    assert {:ok, scope} = Accounts.fetch_scope_by_api_token(token)
    assert scope.user.id == user.id
  end

  test "keeps invalid credentials and non-administrative accounts out of the panel", %{conn: conn} do
    user = Clubeira.Factory.insert(:user)
    assert {:ok, _credential} = Accounts.set_password(user, @password)

    invalid_conn =
      post(conn, "/admin/login", %{
        "email" => user.email,
        "password" => "senha-incorreta"
      })

    assert invalid_conn.status == 401
    assert html_response(invalid_conn, 401) =~ ~s(id="login-error")
    refute get_session(invalid_conn, "backoffice_session_token")

    unauthorized_conn =
      conn
      |> recycle()
      |> post("/admin/login", %{"email" => user.email, "password" => @password})

    assert unauthorized_conn.status == 403
    assert html_response(unauthorized_conn, 403) =~ ~s(id="login-error")
    refute get_session(unauthorized_conn, "backoffice_session_token")
  end

  test "logout revokes the underlying account session", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    user = authenticate_user!(admin_scope.actor_user_id)
    assert {:ok, session} = Accounts.login(user.email, @password)

    conn =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> delete("/admin/logout")

    assert redirected_to(conn) == "/admin/login"
    assert conn.private.plug_session_info == :drop
    assert :error = Accounts.fetch_scope_by_api_token(session.token)
  end

  defp authenticate_user!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    user
  end
end
