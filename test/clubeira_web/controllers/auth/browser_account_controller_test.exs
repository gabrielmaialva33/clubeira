defmodule ClubeiraWeb.Auth.BrowserAccountControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  import Swoosh.TestAssertions

  alias Clubeira.Accounts
  alias Clubeira.Accounts.RequestContext
  alias Clubeira.Factory
  alias Clubeira.LegalFixtures
  alias Clubeira.Mailer

  @password "uma-senha-forte-para-o-browser"

  setup :set_swoosh_global

  test "registers a member with every legal version fixed by the server", %{conn: conn} do
    first_terms = LegalFixtures.registration_terms!()
    second_terms = LegalFixtures.registration_terms!()

    registration_page = get(conn, "/registrar")
    html = html_response(registration_page, 200)

    assert html =~ ~s(id="browser-registration")
    assert html =~ ~s(id="browser-registration-form")
    assert html =~ ~s(id="registration-legal-documents")
    assert html =~ ~s(id="registration-accept-legal-documents")
    refute html =~ first_terms.version_id
    refute html =~ second_terms.version_id
    assert get_resp_header(registration_page, "cache-control") == ["private, no-store"]

    registration_conn =
      post(registration_page, "/registrar", %{
        "registration" => %{
          "email" => "  MEMBRO.BROWSER@Example.Test ",
          "password" => @password
        },
        "accept_legal_documents" => "true",
        "legal_document_version_ids" => [Ecto.UUID.generate(version: 7)]
      })

    assert redirected_to(registration_conn) == "/app"
    token = get_session(registration_conn, "backoffice_session_token")
    assert is_binary(token)
    refute registration_conn.resp_body =~ token
    refute registration_conn |> get_resp_header("set-cookie") |> Enum.join(";") =~ token
    refute registration_conn.resp_body =~ @password
    assert {:ok, scope} = Accounts.fetch_scope_by_api_token(token)
    assert scope.user.email == "membro.browser@example.test"
    assert get_resp_header(registration_conn, "cache-control") == ["private, no-store"]
  end

  test "fails closed when acceptance is missing or the displayed legal set becomes stale", %{
    conn: conn
  } do
    LegalFixtures.registration_terms!()
    registration_page = get(conn, "/registrar")

    missing_acceptance =
      post(registration_page, "/registrar", %{
        "email" => "missing-acceptance@example.test",
        "password" => @password
      })

    assert html_response(missing_acceptance, 422) =~ ~s(id="browser-registration-error")
    refute missing_acceptance.resp_body =~ @password
    refute get_session(missing_acceptance, "backoffice_session_token")

    LegalFixtures.registration_terms!()

    stale_acceptance =
      registration_page
      |> recycle()
      |> post("/registrar", %{
        "email" => "stale-acceptance@example.test",
        "password" => @password,
        "accept_legal_documents" => "true"
      })

    stale_html = html_response(stale_acceptance, 422)
    assert stale_html =~ ~s(id="browser-registration-error")
    refute stale_html =~ @password
    refute get_session(stale_acceptance, "backoffice_session_token")

    accepted_current_set =
      stale_acceptance
      |> recycle()
      |> post("/registrar", %{
        "email" => "stale-acceptance@example.test",
        "password" => @password,
        "accept_legal_documents" => "true"
      })

    assert redirected_to(accepted_current_set) == "/app"
  end

  test "password reset requests are non-enumerating browser responses", %{conn: conn} do
    Factory.insert(:user, email: "known-browser@example.test")

    request_page = get(conn, "/esqueci-minha-senha")
    assert request_page |> html_response(200) =~ ~s(id="password-reset-request-form")
    assert get_resp_header(request_page, "cache-control") == ["private, no-store"]

    known_response =
      post(request_page, "/esqueci-minha-senha", %{
        "password_reset_request" => %{"email" => "  KNOWN-BROWSER@Example.Test "}
      })

    known_html = html_response(known_response, 202)
    assert known_html =~ ~s(id="password-reset-request-sent")
    refute known_html =~ "known-browser@example.test"

    token = receive_email_token("Redefina sua senha do Clubeira", :password_reset_token)

    unknown_response =
      known_response
      |> recycle()
      |> post("/esqueci-minha-senha", %{"email" => "unknown-browser@example.test"})

    unknown_html = html_response(unknown_response, 202)
    assert unknown_html =~ ~s(id="password-reset-request-sent")
    refute unknown_html =~ "unknown-browser@example.test"
    refute unknown_html =~ token
    refute_email_sent()
    assert get_resp_header(unknown_response, "cache-control") == ["private, no-store"]
  end

  test "password reset canonicalizes the URL and keeps the opaque token server-side", %{
    conn: conn
  } do
    user = Factory.insert(:user, email: "reset-browser@example.test")
    assert {:ok, _credential} = Accounts.set_password(user, "senha-antiga-bem-forte")
    assert :ok = Accounts.request_password_reset(user.email, RequestContext.new!())

    token = receive_email_token("Redefina sua senha do Clubeira", :password_reset_token)

    token_redirect = get(conn, "/redefinir-senha?token=#{token}")
    assert redirected_to(token_redirect) == "/redefinir-senha"
    refute token_redirect.resp_body =~ token
    refute token_redirect |> get_resp_header("set-cookie") |> Enum.join(";") =~ token

    reset_page = token_redirect |> recycle() |> get("/redefinir-senha")
    reset_html = html_response(reset_page, 200)
    assert reset_html =~ ~s(id="password-reset-form")
    refute reset_html =~ token

    invalid_response =
      post(reset_page, "/redefinir-senha", %{
        "password" => "curta",
        "token" => "credencial-forjada-pelo-browser"
      })

    invalid_html = html_response(invalid_response, 422)
    assert invalid_html =~ ~s(id="browser-password-reset-error")
    refute invalid_html =~ "curta"
    refute invalid_html =~ token

    completed_response =
      invalid_response
      |> recycle()
      |> post("/redefinir-senha", %{
        "password_reset_completion" => %{
          "password" => "senha-nova-bem-forte-para-browser",
          "token" => "credencial-forjada-pelo-browser"
        }
      })

    completed_html = html_response(completed_response, 200)
    assert completed_html =~ ~s(id="password-reset-completed")
    refute completed_html =~ token
    refute completed_html =~ "senha-nova-bem-forte-para-browser"
    refute get_session(completed_response, "browser_password_reset_token")
    assert {:ok, _session} = Accounts.login(user.email, "senha-nova-bem-forte-para-browser")
    assert get_resp_header(completed_response, "cache-control") == ["private, no-store"]
  end

  test "email verification canonicalizes and consumes only the server-held token", %{conn: conn} do
    terms = LegalFixtures.registration_terms!()

    assert {:ok, session} =
             Accounts.register(
               %{
                 "email" => "verify-browser@example.test",
                 "password" => @password,
                 "legal_document_version_ids" => [terms.version_id]
               },
               RequestContext.new!()
             )

    token = receive_email_token("Confirme seu e-mail do Clubeira", :email_verification_token)

    token_redirect = get(conn, "/verificar-email?token=#{token}")
    assert redirected_to(token_redirect) == "/verificar-email"
    refute token_redirect.resp_body =~ token
    refute token_redirect |> get_resp_header("set-cookie") |> Enum.join(";") =~ token

    verification_page = token_redirect |> recycle() |> get("/verificar-email")
    verification_html = html_response(verification_page, 200)
    assert verification_html =~ ~s(id="email-verification-form")
    refute verification_html =~ token

    verified_response =
      post(verification_page, "/verificar-email", %{
        "token" => "credencial-forjada-pelo-browser"
      })

    verified_html = html_response(verified_response, 200)
    assert verified_html =~ ~s(id="email-verification-completed")
    refute verified_html =~ token
    refute get_session(verified_response, "browser_email_verification_token")
    assert {:ok, refreshed_scope} = Accounts.fetch_scope_by_api_token(session.token)
    assert %DateTime{} = refreshed_scope.user.email_verified_at
    assert get_resp_header(verified_response, "cache-control") == ["private, no-store"]
  end

  test "malformed credential links fail closed without reflecting their token", %{conn: conn} do
    reset_redirect = get(conn, "/redefinir-senha?token=segredo-malformado")
    assert redirected_to(reset_redirect) == "/redefinir-senha"
    refute reset_redirect.resp_body =~ "segredo-malformado"

    reset_page = reset_redirect |> recycle() |> get("/redefinir-senha")
    reset_html = html_response(reset_page, 422)
    assert reset_html =~ ~s(id="browser-password-reset-error")
    refute reset_html =~ ~s(id="password-reset-form")
    refute reset_html =~ "segredo-malformado"

    verification_redirect = get(conn, "/verificar-email?token=outro-segredo-malformado")
    assert redirected_to(verification_redirect) == "/verificar-email"
    refute verification_redirect.resp_body =~ "outro-segredo-malformado"

    verification_page = verification_redirect |> recycle() |> get("/verificar-email")
    verification_html = html_response(verification_page, 422)
    assert verification_html =~ ~s(id="browser-email-verification-error")
    refute verification_html =~ ~s(id="email-verification-form")
    refute verification_html =~ "outro-segredo-malformado"
  end

  test "browser registration is rate limited with an HTML no-store response", %{conn: conn} do
    original_config =
      Application.fetch_env!(:clubeira, ClubeiraWeb.Plugs.CredentialRateLimit)

    Application.put_env(
      :clubeira,
      ClubeiraWeb.Plugs.CredentialRateLimit,
      Keyword.put(original_config, :limiter, ClubeiraWeb.DenyCredentialRateLimiter)
    )

    on_exit(fn ->
      Application.put_env(
        :clubeira,
        ClubeiraWeb.Plugs.CredentialRateLimit,
        original_config
      )
    end)

    LegalFixtures.registration_terms!()
    registration_page = get(conn, "/registrar")

    limited_response =
      post(registration_page, "/registrar", %{
        "registration" => %{
          "email" => "limited-browser@example.test",
          "password" => @password
        },
        "accept_legal_documents" => "true"
      })

    limited_html = html_response(limited_response, 429)
    assert limited_html =~ ~s(id="browser-credential-rate-limited")
    assert get_resp_header(limited_response, "retry-after") == ["2"]
    assert get_resp_header(limited_response, "cache-control") == ["private, no-store"]
  end

  test "duplicate registration stays on the form without reflecting the password", %{conn: conn} do
    LegalFixtures.registration_terms!()
    Factory.insert(:user, email: "existing-browser@example.test")
    registration_page = get(conn, "/registrar")

    response =
      post(registration_page, "/registrar", %{
        "registration" => %{
          "email" => "existing-browser@example.test",
          "password" => @password
        },
        "accept_legal_documents" => "true"
      })

    html = html_response(response, 422)
    assert html =~ ~s(id="browser-registration-form")
    refute html =~ @password
    refute get_session(response, "backoffice_session_token")
  end

  test "unknown well-formed credentials are consumed server-side and fail closed", %{conn: conn} do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    reset_redirect = get(conn, "/redefinir-senha?token=#{token}")
    assert redirected_to(reset_redirect) == "/redefinir-senha"

    reset_response =
      post(reset_redirect, "/redefinir-senha", %{
        "password_reset_completion" => %{
          "password" => "senha-nova-bem-forte-para-token-inexistente"
        }
      })

    reset_html = html_response(reset_response, 422)
    assert reset_html =~ ~s(id="browser-password-reset-error")
    refute reset_html =~ token
    refute get_session(reset_response, "browser_password_reset_token")

    missing_reset =
      reset_response
      |> recycle()
      |> post("/redefinir-senha", %{"password" => "outra-senha-bem-forte"})

    assert html_response(missing_reset, 422) =~ ~s(id="browser-password-reset-error")

    verification_redirect =
      missing_reset
      |> recycle()
      |> get("/verificar-email?token=#{token}")

    assert redirected_to(verification_redirect) == "/verificar-email"

    verification_response = post(verification_redirect, "/verificar-email", %{})
    verification_html = html_response(verification_response, 422)
    assert verification_html =~ ~s(id="browser-email-verification-error")
    refute verification_html =~ token
    refute get_session(verification_response, "browser_email_verification_token")

    missing_verification =
      verification_response
      |> recycle()
      |> post("/verificar-email", %{})

    assert html_response(missing_verification, 422) =~ ~s(id="browser-email-verification-error")
  end

  test "password-reset delivery failure keeps the browser response non-enumerating", %{conn: conn} do
    previous_mailer_config = Application.fetch_env!(:clubeira, Mailer)
    Application.put_env(:clubeira, Mailer, adapter: Clubeira.FailingMailerAdapter)
    on_exit(fn -> Application.put_env(:clubeira, Mailer, previous_mailer_config) end)

    Factory.insert(:user, email: "browser-delivery-failure@example.test")

    response =
      post(conn, "/esqueci-minha-senha", %{
        "email" => "browser-delivery-failure@example.test"
      })

    html = html_response(response, 202)
    assert html =~ ~s(id="password-reset-request-sent")
    refute html =~ "browser-delivery-failure@example.test"
    refute_email_sent()
    assert get_resp_header(response, "cache-control") == ["private, no-store"]
  end

  defp receive_email_token(subject, message_tag) do
    assert_email_sent(fn email ->
      assert email.subject == subject
      assert [_, token] = Regex.run(~r/[?&]token=([A-Za-z0-9_-]{43})/, email.text_body)
      send(self(), {message_tag, token})
      true
    end)

    assert_receive {^message_tag, token}
    token
  end
end
