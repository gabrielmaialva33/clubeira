defmodule ClubeiraWeb.Platform.PrivacyRequestLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.People
  alias Clubeira.Privacy
  alias Clubeira.PrivacyFixtures
  alias Clubeira.Repo
  alias Clubeira.Tenancy.ActorScope

  @password "uma-senha-forte-para-o-detalhe-lgpd-web"

  test "transitions the server-bound request and expected status through the detail UI", %{
    conn: conn
  } do
    request = privacy_request!()
    session = privacy_session!()

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(~p"/platform/privacy/requests/#{request.id}")

    assert has_element?(view, "#platform-privacy-request-page[data-status='received']")
    assert has_element?(view, "#platform-nav-privacy[aria-current='page']")
    assert has_element?(view, "#privacy-request-events #privacy-request-event-0")
    assert has_element?(view, "#privacy-request-transition-form")
    refute has_element?(view, "input[name='request_id']")
    refute has_element?(view, "input[name='transition[expected_status]']")

    view
    |> form("#privacy-request-transition-form",
      transition: %{action: "reject", rejection_reason: ""}
    )
    |> render_submit()

    assert has_element?(view, "#platform-privacy-request-page[data-status='received']")
    assert has_element?(view, "#privacy-request-transition-form p.text-red-600")

    view
    |> render_submit("transition", %{
      "request_id" => Ecto.UUID.generate(version: 7),
      "transition" => %{
        "action" => "start_processing",
        "expected_status" => "completed",
        "rejection_reason" => ""
      }
    })

    assert has_element?(view, "#platform-privacy-request-page[data-status='in_progress']")
    assert has_element?(view, "#privacy-request-events #privacy-request-event-1")

    actor_scope =
      ActorScope.new!(session.account_scope.user.id, Ecto.UUID.generate(version: 7))

    assert {:ok, %{id: request_id, status: "in_progress"}} =
             Privacy.get_platform_request(actor_scope, request.id)

    assert request_id == request.id
  end

  test "revalidates the current platform role before a transition", %{conn: conn} do
    request = privacy_request!()
    session = privacy_session!()

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(~p"/platform/privacy/requests/#{request.id}")

    session.membership
    |> Ecto.Changeset.change(status: "revoked")
    |> Repo.update!()

    assert {:error, {:redirect, %{to: "/platform"}}} =
             view
             |> form("#privacy-request-transition-form",
               transition: %{action: "start_processing", rejection_reason: ""}
             )
             |> render_submit()
  end

  test "returns unknown and malformed request identities to the server-owned queue", %{conn: conn} do
    session = privacy_session!()
    conn = init_test_session(conn, %{"backoffice_session_token" => session.token})

    assert {:error, {:redirect, %{to: "/platform/privacy/requests"}}} =
             live(conn, ~p"/platform/privacy/requests/#{Ecto.UUID.generate(version: 7)}")

    assert {:error, {:redirect, %{to: "/platform/privacy/requests"}}} =
             conn
             |> recycle()
             |> init_test_session(%{"backoffice_session_token" => session.token})
             |> live("/platform/privacy/requests/not-a-request-id")
  end

  test "revalidates the persisted session before a transition", %{conn: conn} do
    request = privacy_request!()
    session = privacy_session!()

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(~p"/platform/privacy/requests/#{request.id}")

    assert :ok = Accounts.revoke_session(session.account_scope)

    view
    |> form("#privacy-request-transition-form",
      transition: %{action: "start_processing", rejection_reason: ""}
    )
    |> render_submit()

    assert_redirect(view, "/platform/login")
  end

  test "reloads the current request after a stale transition", %{conn: conn} do
    request = privacy_request!()
    session = privacy_session!()

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(~p"/platform/privacy/requests/#{request.id}")

    actor_scope =
      ActorScope.new!(session.account_scope.user.id, Ecto.UUID.generate(version: 7))

    assert {:ok, %{request: %{status: "identity_verification"}}} =
             Privacy.transition_request(actor_scope, request.id, %{
               "action" => "start_identity_verification",
               "expected_status" => "received"
             })

    view
    |> form("#privacy-request-transition-form",
      transition: %{action: "start_processing", rejection_reason: ""}
    )
    |> render_submit()

    assert has_element?(
             view,
             "#platform-privacy-request-page[data-status='identity_verification']"
           )

    assert has_element?(view, "#flash-error")
    assert has_element?(view, "#privacy-request-events #privacy-request-event-1")
  end

  test "rejects a malformed transition event without losing the request", %{conn: conn} do
    request = privacy_request!()
    session = privacy_session!()

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(~p"/platform/privacy/requests/#{request.id}")

    render_submit(view, "transition", %{})

    assert has_element?(view, "#platform-privacy-request-page[data-status='received']")
    assert has_element?(view, "#flash-error")
  end

  test "completes an in-progress request into a terminal server state", %{conn: conn} do
    request = privacy_request!()
    session = privacy_session!()

    actor_scope =
      ActorScope.new!(session.account_scope.user.id, Ecto.UUID.generate(version: 7))

    assert {:ok, %{request: %{status: "in_progress"}}} =
             Privacy.transition_request(actor_scope, request.id, %{
               "action" => "start_processing",
               "expected_status" => "received"
             })

    {:ok, view, _html} =
      conn
      |> put_req_header("accept-language", "en")
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(~p"/platform/privacy/requests/#{request.id}")

    expected_due_at = Calendar.strftime(request.due_at, "%Y-%m-%d %H:%M UTC")
    assert has_element?(view, "#platform-privacy-request-page", expected_due_at)

    view
    |> form("#privacy-request-transition-form",
      transition: %{action: "complete", rejection_reason: ""}
    )
    |> render_submit()

    assert has_element?(view, "#platform-privacy-request-page[data-status='completed']")
    assert has_element?(view, "#privacy-request-terminal")
    refute has_element?(view, "#privacy-request-transition-form")
    assert has_element?(view, "#privacy-request-events #privacy-request-event-2")
  end

  defp privacy_request! do
    requester = Clubeira.Factory.insert(:user)
    scope = ActorScope.new!(requester.id, Ecto.UUID.generate(version: 7))

    assert {:ok, _profile} =
             People.put_self_profile(scope, %{"display_name" => "Titular da solicitação"})

    assert {:ok, %{request: request}} =
             Privacy.submit_request(scope, %{
               "client_request_id" => Ecto.UUID.generate(version: 7),
               "request_type" => "access"
             })

    request
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
