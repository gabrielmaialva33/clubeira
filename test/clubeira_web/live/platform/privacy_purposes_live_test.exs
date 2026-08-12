defmodule ClubeiraWeb.Platform.PrivacyPurposesLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.Privacy
  alias Clubeira.PrivacyFixtures
  alias Clubeira.Repo
  alias Clubeira.Tenancy.ActorScope

  @password "uma-senha-forte-para-finalidades-lgpd-web"

  test "creates a purpose by selecting readable current legal evidence", %{conn: conn} do
    legal = PrivacyFixtures.consent_purpose!()
    session = privacy_session!()

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(~p"/platform/privacy/purposes")

    assert has_element?(view, "#platform-privacy-purposes-page")
    assert has_element?(view, "#platform-nav-privacy[aria-current='page']")

    assert has_element?(
             view,
             "#processing-purpose-legal-version-id option[value='#{legal.version_id}']",
             "pt-BR v1"
           )

    refute has_element?(view, "#processing-purpose-legal-version-id[type='text']")

    code = "service-quality-#{System.unique_integer([:positive])}"

    view
    |> form("#processing-purpose-form",
      processing_purpose: %{
        code: code,
        name: "Qualidade do serviço",
        legal_basis: "consent",
        legal_document_version_id: legal.version_id,
        status: "active"
      }
    )
    |> render_submit()

    assert has_element?(view, "#platform-processing-purposes [data-code='#{code}']")
    assert has_element?(view, "#flash-info")
  end

  test "keeps an existing purpose code server-bound while updating it", %{conn: conn} do
    purpose = PrivacyFixtures.consent_purpose!()
    session = privacy_session!()

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(~p"/platform/privacy/purposes")

    view
    |> element("#processing-purpose-edit-#{purpose.purpose_id}")
    |> render_click()

    assert has_element?(view, "#processing-purpose-editing-code", purpose.code)
    refute has_element?(view, "input[name='processing_purpose[code]']")

    tampered_code = "tampered-#{System.unique_integer([:positive])}"

    view
    |> render_submit("save_purpose", %{
      "processing_purpose" => %{
        "code" => tampered_code,
        "name" => "Finalidade revisada",
        "legal_basis" => "consent",
        "legal_document_version_id" => purpose.version_id,
        "status" => "active"
      }
    })

    assert has_element?(
             view,
             "#platform-processing-purposes [data-code='#{purpose.code}']",
             "Finalidade revisada"
           )

    refute has_element?(view, "#platform-processing-purposes [data-code='#{tampered_code}']")

    actor_scope =
      ActorScope.new!(session.account_scope.user.id, Ecto.UUID.generate(version: 7))

    assert {:ok, purposes} = Privacy.list_processing_purposes(actor_scope)
    assert Enum.any?(purposes, &(&1.code == purpose.code and &1.name == "Finalidade revisada"))
    refute Enum.any?(purposes, &(&1.code == tampered_code))
  end

  test "revalidates legal evidence when the selected basis changes", %{conn: conn} do
    legal = PrivacyFixtures.consent_purpose!()
    session = privacy_session!()

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(~p"/platform/privacy/purposes")

    render_change(view, "validate_purpose", %{
      "processing_purpose" => %{
        "code" => "invalid-basis",
        "name" => "Base inválida",
        "legal_basis" => "invented",
        "status" => "active"
      }
    })

    assert has_element?(view, "#processing-purpose-no-legal-options")

    refute has_element?(
             view,
             "#processing-purpose-legal-version-id option[value='#{legal.version_id}']"
           )
  end

  test "revalidates the privacy role before refreshing legal evidence", %{conn: conn} do
    PrivacyFixtures.consent_purpose!()
    session = privacy_session!()

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(~p"/platform/privacy/purposes")

    session.membership
    |> Ecto.Changeset.change(status: "revoked")
    |> Repo.update!()

    render_change(view, "validate_purpose", %{
      "processing_purpose" => %{"legal_basis" => "contract"}
    })

    assert_redirect(view, "/platform")
  end

  test "rejects malformed form and edit events without terminating the workspace", %{conn: conn} do
    PrivacyFixtures.consent_purpose!()
    session = privacy_session!()

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(~p"/platform/privacy/purposes")

    render_change(view, "validate_purpose", %{})
    assert has_element?(view, "#flash-error")

    render_click(view, "edit_purpose", %{"purpose-id" => Ecto.UUID.generate(version: 7)})
    assert has_element?(view, "#flash-error")

    render_click(view, "edit_purpose", %{})
    assert has_element?(view, "#platform-privacy-purposes-page")

    render_submit(view, "save_purpose", %{})
    assert has_element?(view, "#processing-purpose-form")
  end

  test "renders a safe blank form when no current legal evidence exists", %{conn: conn} do
    session = privacy_session!()

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(~p"/platform/privacy/purposes")

    assert has_element?(view, "#processing-purpose-no-legal-options")
    assert has_element?(view, "#processing-purpose-code")
    assert has_element?(view, "#platform-processing-purposes-empty")
  end

  test "switches from an existing purpose back to a new server-initialized form", %{conn: conn} do
    purpose = PrivacyFixtures.consent_purpose!()
    session = privacy_session!()

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(~p"/platform/privacy/purposes")

    view |> element("#processing-purpose-edit-#{purpose.purpose_id}") |> render_click()
    assert has_element?(view, "#processing-purpose-editing-code", purpose.code)

    view |> element("#processing-purpose-new") |> render_click()
    assert has_element?(view, "#processing-purpose-code")
    refute has_element?(view, "#processing-purpose-editing-code")
  end

  test "keeps domain validation and unavailable legal evidence on the form", %{conn: conn} do
    legal = PrivacyFixtures.consent_purpose!()
    session = privacy_session!()

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(~p"/platform/privacy/purposes")

    view
    |> form("#processing-purpose-form",
      processing_purpose: %{
        code: "invalid-name",
        name: "x",
        legal_basis: "consent",
        legal_document_version_id: legal.version_id,
        status: "active"
      }
    )
    |> render_submit()

    assert has_element?(view, "#processing-purpose-form p.text-red-600")
    refute has_element?(view, "#platform-processing-purposes [data-code='invalid-name']")

    render_submit(view, "save_purpose", %{
      "processing_purpose" => %{
        "code" => "unavailable-evidence",
        "name" => "Evidência indisponível",
        "legal_basis" => "consent",
        "legal_document_version_id" => Ecto.UUID.generate(version: 7),
        "status" => "active"
      }
    })

    assert has_element?(view, "#flash-error")
    refute has_element?(view, "#platform-processing-purposes [data-code='unavailable-evidence']")
  end

  test "revalidates the persisted session before saving a purpose", %{conn: conn} do
    legal = PrivacyFixtures.consent_purpose!()
    session = privacy_session!()

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(~p"/platform/privacy/purposes")

    assert :ok = Accounts.revoke_session(session.account_scope)

    render_submit(view, "save_purpose", %{
      "processing_purpose" => %{
        "code" => "expired-session-purpose",
        "name" => "Sessão expirada",
        "legal_basis" => "consent",
        "legal_document_version_id" => legal.version_id,
        "status" => "active"
      }
    })

    assert_redirect(view, "/platform/login")
  end

  test "revalidates platform access before changing the purpose editor mode", %{conn: conn} do
    purpose = PrivacyFixtures.consent_purpose!()
    expired = privacy_session!()

    {:ok, expired_view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => expired.token})
      |> live(~p"/platform/privacy/purposes")

    assert :ok = Accounts.revoke_session(expired.account_scope)
    render_click(expired_view, "new_purpose", %{})
    assert_redirect(expired_view, "/platform/login")

    revoked = privacy_session!()

    {:ok, revoked_view, _html} =
      conn
      |> recycle()
      |> init_test_session(%{"backoffice_session_token" => revoked.token})
      |> live(~p"/platform/privacy/purposes")

    revoked.membership
    |> Ecto.Changeset.change(status: "revoked")
    |> Repo.update!()

    render_click(revoked_view, "edit_purpose", %{"purpose-id" => purpose.purpose_id})
    assert_redirect(revoked_view, "/platform")
  end

  defp privacy_session! do
    officer = Clubeira.Factory.insert(:user)
    %{membership: membership} = PrivacyFixtures.privacy_officer!(officer)

    assert {:ok, _credential} = Accounts.set_password(officer, @password)
    assert {:ok, session} = Accounts.login(officer.email, @password)
    assert {:ok, account_scope} = Accounts.fetch_scope_by_api_token(session.token)

    %{token: session.token, account_scope: account_scope, membership: membership}
  end
end
