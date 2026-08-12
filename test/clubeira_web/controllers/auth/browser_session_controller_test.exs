defmodule ClubeiraWeb.Auth.BrowserSessionControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.Accounts.User
  alias Clubeira.PrivacyFixtures
  alias Clubeira.RedemptionsFixtures
  alias Clubeira.Repo
  alias Clubeira.ReviewsFixtures
  alias ClubeiraWeb.PartnerBrowserFixtures
  alias ClubeiraWeb.Plugs.CredentialRateLimit

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

  test "renders an isolated platform login", %{conn: conn} do
    conn = get(conn, "/platform/login")
    response = html_response(conn, 200)

    assert response =~ ~s(id="platform-login")
    assert response =~ ~s(id="platform-login-form")
    assert response =~ ~s(action="/platform/login")
    refute response =~ ~s(action="/admin/login")
    assert response =~ "Administração global"
    assert response =~ "Entre na plataforma"
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
  end

  test "renders an isolated member login", %{conn: conn} do
    conn = get(conn, "/app/login")
    response = html_response(conn, 200)

    assert response =~ ~s(id="member-login")
    assert response =~ ~s(id="member-login-form")
    assert response =~ ~s(action="/app/login")

    document = LazyHTML.from_document(response)

    assert [_register_link] =
             document
             |> LazyHTML.query(~s(#member-register-link[href="/registrar"]))
             |> LazyHTML.to_tree()

    assert [_password_reset_link] =
             document
             |> LazyHTML.query(~s(#member-password-reset-link[href="/esqueci-minha-senha"]))
             |> LazyHTML.to_tree()

    refute response =~ ~s(action="/admin/login")
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
  end

  test "renders an isolated partner login", %{conn: conn} do
    conn = get(conn, "/partner/login")
    response = html_response(conn, 200)

    assert response =~ ~s(id="partner-login")
    assert response =~ ~s(id="partner-login-form")
    assert response =~ ~s(action="/partner/login")
    refute response =~ ~s(action="/admin/login")
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
  end

  test "browser login rate limits render HTML on every surface", %{conn: conn} do
    previous = Application.fetch_env!(:clubeira, CredentialRateLimit)

    Application.put_env(
      :clubeira,
      CredentialRateLimit,
      Keyword.put(previous, :limiter, ClubeiraWeb.DenyCredentialRateLimiter)
    )

    on_exit(fn -> Application.put_env(:clubeira, CredentialRateLimit, previous) end)

    Enum.reduce(
      ["/app/login", "/admin/login", "/partner/login", "/platform/login"],
      conn,
      fn path, conn ->
        response = post(conn, path, %{"email" => "member@example.test", "password" => @password})

        html = html_response(response, 429)
        assert html =~ ~s(id="browser-credential-rate-limited")

        assert html
               |> LazyHTML.from_document()
               |> LazyHTML.query(~s(#credential-rate-limited-back[href="#{path}"]))
               |> LazyHTML.to_tree()
               |> length() == 1

        assert get_resp_header(response, "content-type") |> List.first() =~ "text/html"
        assert get_resp_header(response, "retry-after") == ["2"]

        recycle(response)
      end
    )
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

  test "starts a platform browser session for a platform-only user", %{conn: conn} do
    user = Clubeira.Factory.insert(:user)
    PrivacyFixtures.privacy_officer!(user)
    assert {:ok, _credential} = Accounts.set_password(user, @password)

    conn =
      post(conn, "/platform/login", %{
        "email" => user.email,
        "password" => @password
      })

    assert redirected_to(conn) == "/platform"

    token = get_session(conn, "backoffice_session_token")
    assert is_binary(token)
    refute conn |> get_resp_header("set-cookie") |> Enum.join(";") =~ token
    assert {:ok, scope} = Accounts.fetch_scope_by_api_token(token)
    assert scope.user.id == user.id
  end

  test "starts a member browser session without requiring administrative roles", %{conn: conn} do
    user = Clubeira.Factory.insert(:user)
    assert {:ok, _credential} = Accounts.set_password(user, @password)

    conn =
      post(conn, "/app/login", %{
        "email" => user.email,
        "password" => @password
      })

    assert redirected_to(conn) == "/app"
    assert is_binary(get_session(conn, "backoffice_session_token"))
  end

  test "starts a partner browser session only for a currently assigned partner", %{conn: conn} do
    fixture = RedemptionsFixtures.create!()
    %{user: user} = PartnerBrowserFixtures.grant_partner!(fixture)
    assert {:ok, _credential} = Accounts.set_password(user, @password)

    conn =
      post(conn, "/partner/login", %{
        "email" => user.email,
        "password" => @password
      })

    assert redirected_to(conn) == "/partner"
    assert is_binary(get_session(conn, "backoffice_session_token"))
  end

  test "keeps the browser surfaces isolated by their current authorization", %{conn: conn} do
    platform_user = Clubeira.Factory.insert(:user)
    PrivacyFixtures.privacy_officer!(platform_user)
    assert {:ok, _credential} = Accounts.set_password(platform_user, @password)

    platform_on_tenant_conn =
      post(conn, "/admin/login", %{
        "email" => platform_user.email,
        "password" => @password
      })

    assert platform_on_tenant_conn.status == 403
    refute get_session(platform_on_tenant_conn, "backoffice_session_token")

    fixture = RedemptionsFixtures.create!()
    tenant_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    tenant_user = authenticate_user!(tenant_scope.actor_user_id)

    tenant_on_platform_conn =
      conn
      |> recycle()
      |> post("/platform/login", %{
        "email" => tenant_user.email,
        "password" => @password
      })

    assert tenant_on_platform_conn.status == 403

    assert html_response(tenant_on_platform_conn, 403) =~
             "Esta conta não possui acesso à plataforma."

    refute html_response(tenant_on_platform_conn, 403) =~
             "Esta conta não possui acesso ao backoffice."

    refute get_session(tenant_on_platform_conn, "backoffice_session_token")
  end

  test "uses the selected browser surface as the deterministic destination for a dual-role user",
       %{
         conn: conn
       } do
    fixture = RedemptionsFixtures.create!()
    admin_scope = ReviewsFixtures.grant_moderator!(fixture, role_key: "admin")
    user = authenticate_user!(admin_scope.actor_user_id)
    PrivacyFixtures.privacy_officer!(user)

    admin_conn =
      post(conn, "/admin/login", %{
        "email" => user.email,
        "password" => @password
      })

    assert redirected_to(admin_conn) == "/admin"

    platform_conn =
      conn
      |> recycle()
      |> post("/platform/login", %{
        "email" => user.email,
        "password" => @password
      })

    assert redirected_to(platform_conn) == "/platform"
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

  test "platform logout revokes the underlying account session", %{conn: conn} do
    user = Clubeira.Factory.insert(:user)
    PrivacyFixtures.privacy_officer!(user)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)

    conn =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> delete("/platform/logout")

    assert redirected_to(conn) == "/platform/login"
    assert conn.private.plug_session_info == :drop
    assert :error = Accounts.fetch_scope_by_api_token(session.token)
  end

  test "member logout revokes the underlying account session", %{conn: conn} do
    user = Clubeira.Factory.insert(:user)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)

    conn =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> delete("/app/logout")

    assert redirected_to(conn) == "/app/login"
    assert conn.private.plug_session_info == :drop
    assert :error = Accounts.fetch_scope_by_api_token(session.token)
  end

  test "partner logout revokes the underlying account session", %{conn: conn} do
    user = Clubeira.Factory.insert(:user)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)

    conn =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> delete("/partner/logout")

    assert redirected_to(conn) == "/partner/login"
    assert conn.private.plug_session_info == :drop
    assert :error = Accounts.fetch_scope_by_api_token(session.token)
  end

  test "incomplete platform credentials stay on the selected HTML surface", %{conn: conn} do
    response =
      post(conn, "/platform/login", %{
        "email" => "operator@example.test",
        "unexpected_password" => @password
      })

    html = html_response(response, 401)
    assert html =~ ~s(id="platform-login-form")
    assert html =~ "operator@example.test"
    refute html =~ @password
    refute get_session(response, "backoffice_session_token")
    assert get_resp_header(response, "cache-control") == ["private, no-store"]
  end

  test "ordinary accounts cannot enter the partner surface", %{conn: conn} do
    user = Clubeira.Factory.insert(:user)
    assert {:ok, _credential} = Accounts.set_password(user, @password)

    response =
      post(conn, "/partner/login", %{
        "email" => user.email,
        "password" => @password
      })

    assert response.status == 403

    assert html_response(response, 403) =~
             "Esta conta não possui acesso vigente de parceiro."

    refute get_session(response, "backoffice_session_token")
  end

  test "anonymous logout is idempotent on every browser surface", %{conn: conn} do
    Enum.reduce(
      [
        {"/admin/logout", "/admin/login"},
        {"/platform/logout", "/platform/login"},
        {"/app/logout", "/app/login"},
        {"/partner/logout", "/partner/login"}
      ],
      conn,
      fn {path, destination}, conn ->
        response = delete(conn, path)
        assert redirected_to(response) == destination
        assert response.private.plug_session_info == :drop
        recycle(response)
      end
    )
  end

  defp authenticate_user!(user_id) do
    user = Repo.get!(User, user_id)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    user
  end
end
