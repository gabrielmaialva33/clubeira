defmodule ClubeiraWeb.Member.PrivacyLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.People
  alias Clubeira.People.UserPersonLink
  alias Clubeira.Privacy
  alias Clubeira.PrivacyFixtures
  alias Clubeira.Repo
  alias Clubeira.Tenancy.ActorScope

  @password "uma-senha-forte-para-a-privacidade-do-membro"

  test "shows the actor privacy state without exposing command identities", %{conn: conn} do
    %{purpose: purpose, session: session} = privacy_member!()

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/privacy")

    assert has_element?(view, "#member-privacy")
    assert has_element?(view, "#member-nav-privacy[href='/app/privacy']")
    assert has_element?(view, "#member-consent-#{purpose.code}", purpose.name)
    assert has_element?(view, "#member-privacy-requests .hidden.only\\:block")

    refute has_element?(view, "input[name='purpose_code']")
    refute has_element?(view, "input[name='legal_document_version_id']")
    refute has_element?(view, "input[name='privacy_request[client_request_id]']")
  end

  test "uses the current server-side legal evidence when changing consent", %{conn: conn} do
    %{purpose: purpose, scope: scope, session: session} = privacy_member!()

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/privacy")

    render_click(view, "put_consent", %{
      "purpose-code" => purpose.code,
      "state" => "granted",
      "legal_document_version_id" => Ecto.UUID.generate(version: 7)
    })

    assert has_element?(view, "#member-consent-#{purpose.code}[data-state='granted']")

    assert {:ok, [consent]} = Privacy.list_consents(scope)
    assert consent.state == "granted"
    assert consent.legal_document_version_id == purpose.version_id

    view
    |> element("#withdraw-consent-#{purpose.code}")
    |> render_click()

    assert has_element?(view, "#member-consent-#{purpose.code}[data-state='withdrawn']")
    assert {:ok, [%{state: "withdrawn"}]} = Privacy.list_consents(scope)
  end

  test "submits a request with server-owned idempotency and requester identities", %{conn: conn} do
    %{scope: scope, session: session} = privacy_member!()
    tampered_request_id = Ecto.UUID.generate(version: 7)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/privacy")

    render_submit(view, "submit_request", %{
      "privacy_request" => %{
        "request_type" => "deletion",
        "client_request_id" => tampered_request_id,
        "requester_user_id" => Ecto.UUID.generate(version: 7)
      }
    })

    assert has_element?(view, "#member-privacy-requests [data-request-type='deletion']")
    assert has_element?(view, "#flash-info")

    assert {:ok, [request]} = Privacy.list_requests(scope)
    assert request.request_type == "deletion"
    refute request.client_request_id == tampered_request_id
  end

  test "revalidates the session before every privacy mutation", %{conn: conn} do
    consent_member = privacy_member!()

    {:ok, consent_view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => consent_member.session.token})
      |> live("/app/privacy")

    revoke!(consent_member.session.token)

    assert {:error, {:redirect, %{to: "/app/login"}}} =
             render_click(consent_view, "put_consent", %{
               "purpose-code" => consent_member.purpose.code,
               "state" => "granted"
             })

    assert {:ok, consents} = Privacy.list_consents(consent_member.scope)

    assert Enum.find(consents, &(&1.processing_purpose.code == consent_member.purpose.code)).state ==
             "not_set"

    request_member = privacy_member!()

    {:ok, request_view, _html} =
      conn
      |> recycle()
      |> init_test_session(%{"backoffice_session_token" => request_member.session.token})
      |> live("/app/privacy")

    revoke!(request_member.session.token)

    assert {:error, {:redirect, %{to: "/app/login"}}} =
             render_submit(request_view, "submit_request", %{
               "privacy_request" => %{"request_type" => "access"}
             })

    assert {:ok, []} = Privacy.list_requests(request_member.scope)
  end

  test "redirects members without a personal profile to complete it", %{conn: conn} do
    user = Clubeira.Factory.insert(:user)
    session = authenticate!(user)

    assert {:error, {:redirect, %{to: "/app/profile"}}} =
             conn
             |> init_test_session(%{"backoffice_session_token" => session.token})
             |> live("/app/privacy")
  end

  test "rechecks the personal profile before consent and request writes", %{conn: conn} do
    consent_member = privacy_member!()

    {:ok, consent_view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => consent_member.session.token})
      |> live("/app/privacy")

    revoke_self_profile_link!(consent_member.user)

    assert {:error, {:redirect, %{to: "/app/profile"}}} =
             render_click(consent_view, "put_consent", %{
               "purpose-code" => consent_member.purpose.code,
               "state" => "granted"
             })

    request_member = privacy_member!()

    {:ok, request_view, _html} =
      conn
      |> recycle()
      |> init_test_session(%{"backoffice_session_token" => request_member.session.token})
      |> live("/app/privacy")

    revoke_self_profile_link!(request_member.user)

    assert {:error, {:redirect, %{to: "/app/profile"}}} =
             render_submit(request_view, "submit_request", %{
               "privacy_request" => %{"request_type" => "access"}
             })
  end

  test "renders every operational request status with the English timestamp", %{conn: conn} do
    %{scope: scope, session: session} = privacy_member!()
    officer = Clubeira.Factory.insert(:user)
    PrivacyFixtures.privacy_officer!(officer)
    officer_scope = ActorScope.new!(officer.id, Ecto.UUID.generate(version: 7))

    requests = [
      request_with_status!(scope, officer_scope, "access", :identity_verification),
      request_with_status!(scope, officer_scope, "confirmation", :in_progress),
      request_with_status!(scope, officer_scope, "correction", :completed),
      request_with_status!(scope, officer_scope, "portability", :partially_completed),
      request_with_status!(scope, officer_scope, "deletion", :rejected),
      request_with_status!(scope, officer_scope, "anonymization", :cancelled)
    ]

    {:ok, view, _html} =
      conn
      |> put_req_header("accept-language", "en")
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/privacy")

    Enum.each(requests, fn request ->
      assert has_element?(
               view,
               "#member-privacy-request-#{request.id}[data-status='#{request.status}']"
             )
    end)

    expected_timestamp =
      requests
      |> List.first()
      |> Map.fetch!(:inserted_at)
      |> Calendar.strftime("%Y-%m-%d · %H:%M")

    assert has_element?(view, "#member-privacy-requests", expected_timestamp)
  end

  test "keeps malformed consent and data request payloads at the boundary", %{conn: conn} do
    %{purpose: purpose, scope: scope, session: session} = privacy_member!()

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live("/app/privacy")

    render_click(view, "put_consent", %{
      "purpose-code" => purpose.code,
      "state" => "not-a-state"
    })

    render_click(view, "put_consent", %{
      "purpose-code" => "missing-purpose",
      "state" => "granted"
    })

    render_click(view, "put_consent", %{})

    render_change(view, "validate_request", %{
      "privacy_request" => %{"request_type" => "not-a-request"}
    })

    assert has_element?(view, "#privacy_request_request_type.border-red-500")

    render_submit(view, "submit_request", %{
      "privacy_request" => %{"request_type" => "not-a-request"}
    })

    render_change(view, "validate_request", %{})
    render_submit(view, "submit_request", %{})

    assert has_element?(view, "#flash-error")
    assert {:ok, []} = Privacy.list_requests(scope)
  end

  defp privacy_member! do
    user = Clubeira.Factory.insert(:user)
    scope = ActorScope.new!(user.id, Ecto.UUID.generate(version: 7))

    assert {:ok, _profile} =
             People.put_self_profile(scope, %{"display_name" => "Titular da privacidade"})

    purpose = PrivacyFixtures.consent_purpose!()
    session = authenticate!(user)

    %{purpose: purpose, session: session, scope: scope, user: user}
  end

  defp revoke_self_profile_link!(user) do
    Clubeira.TestDatabaseRole.as_owner(fn ->
      user
      |> then(&Repo.get_by!(UserPersonLink, user_id: &1.id, relationship: "self"))
      |> Ecto.Changeset.change(status: "revoked")
      |> Repo.update!()
    end)
  end

  defp request_with_status!(requester_scope, officer_scope, request_type, status) do
    assert {:ok, %{request: request}} =
             Privacy.submit_request(requester_scope, %{
               "client_request_id" => Ecto.UUID.generate(version: 7),
               "request_type" => request_type
             })

    status
    |> transition_path()
    |> Enum.reduce(request, fn {action, expected_status}, current ->
      attributes = %{
        "action" => action,
        "expected_status" => expected_status
      }

      attributes =
        if action == "reject",
          do: Map.put(attributes, "rejection_reason", "Identity could not be verified."),
          else: attributes

      assert {:ok, %{request: updated}} =
               Privacy.transition_request(officer_scope, current.id, attributes)

      updated
    end)
  end

  defp transition_path(:identity_verification),
    do: [{"start_identity_verification", "received"}]

  defp transition_path(:in_progress), do: [{"start_processing", "received"}]

  defp transition_path(:completed),
    do: [{"start_processing", "received"}, {"complete", "in_progress"}]

  defp transition_path(:partially_completed),
    do: [{"start_processing", "received"}, {"partially_complete", "in_progress"}]

  defp transition_path(:rejected), do: [{"reject", "received"}]
  defp transition_path(:cancelled), do: [{"cancel", "received"}]

  defp authenticate!(user) do
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    session
  end

  defp revoke!(token) do
    assert {:ok, account_scope} = Accounts.fetch_scope_by_api_token(token)
    assert :ok = Accounts.revoke_session(account_scope)
  end
end
