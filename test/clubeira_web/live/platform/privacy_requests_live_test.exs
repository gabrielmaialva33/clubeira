defmodule ClubeiraWeb.Platform.PrivacyRequestsLiveTest do
  use ClubeiraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Clubeira.Accounts
  alias Clubeira.People
  alias Clubeira.Privacy
  alias Clubeira.PrivacyFixtures
  alias Clubeira.Repo
  alias Clubeira.Tenancy.ActorScope

  @password "uma-senha-forte-para-a-fila-lgpd-web"

  test "lists global privacy requests through the authorized platform UI", %{conn: conn} do
    request = privacy_request!()
    session = privacy_session!()

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(~p"/platform/privacy/requests")

    assert has_element?(view, "#platform-privacy-requests-page")
    assert has_element?(view, "#platform-nav-privacy[aria-current='page']")
    assert has_element?(view, "#platform-privacy-requests #privacy-request-#{request.id}")
    assert has_element?(view, "#privacy-request-#{request.id}[data-status='received']")
    refute has_element?(view, "input[name='request_id']")
    refute has_element?(view, "input[name='status']")
  end

  test "appends the next keyset page without accepting a cursor from the browser", %{conn: conn} do
    requests = privacy_requests!(21)
    oldest = List.first(requests)
    newest = List.last(requests)
    session = privacy_session!()

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(~p"/platform/privacy/requests")

    assert has_element?(view, "#privacy-request-#{newest.id}")
    refute has_element?(view, "#privacy-request-#{oldest.id}")
    assert has_element?(view, "#platform-privacy-requests-load-more")
    refute has_element?(view, "#platform-privacy-requests-load-more[phx-value-after]")

    view
    |> element("#platform-privacy-requests-load-more")
    |> render_click()

    assert has_element?(view, "#privacy-request-#{oldest.id}")
    refute has_element?(view, "#platform-privacy-requests-load-more")
  end

  test "rejects a malformed initial cursor and returns to the canonical queue", %{conn: conn} do
    session = privacy_session!()

    assert {:error, {:redirect, %{to: "/platform/privacy/requests"}}} =
             conn
             |> init_test_session(%{"backoffice_session_token" => session.token})
             |> live(~p"/platform/privacy/requests?#{[after: "malformed"]}")
  end

  test "revalidates the privacy role before loading another queue page", %{conn: conn} do
    privacy_requests!(21)
    session = privacy_session!()

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(~p"/platform/privacy/requests")

    session.membership
    |> Ecto.Changeset.change(status: "revoked")
    |> Repo.update!()

    view
    |> element("#platform-privacy-requests-load-more")
    |> render_click()

    assert_redirect(view, "/platform")
  end

  test "revalidates the persisted session before loading another queue page", %{conn: conn} do
    privacy_requests!(21)
    session = privacy_session!()

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(~p"/platform/privacy/requests")

    assert :ok = Accounts.revoke_session(session.account_scope)

    view
    |> element("#platform-privacy-requests-load-more")
    |> render_click()

    assert_redirect(view, "/platform/login")
  end

  test "ignores an extra load-more event after reaching the queue end", %{conn: conn} do
    privacy_request!()
    session = privacy_session!()

    {:ok, view, _html} =
      conn
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(~p"/platform/privacy/requests")

    refute has_element?(view, "#platform-privacy-requests-load-more")
    render_click(view, "load_more", %{})
    assert has_element?(view, "#platform-privacy-requests-page")
  end

  test "formats the global queue with the authenticated browser locale", %{conn: conn} do
    request = privacy_request!()
    session = privacy_session!()
    expected_timestamp = Calendar.strftime(request.inserted_at, "%Y-%m-%d %H:%M UTC")

    {:ok, view, _html} =
      conn
      |> put_req_header("accept-language", "en")
      |> init_test_session(%{"backoffice_session_token" => session.token})
      |> live(~p"/platform/privacy/requests")

    assert has_element?(view, "#privacy-request-#{request.id}", expected_timestamp)
  end

  defp privacy_request! do
    [request] = privacy_requests!(1)
    request
  end

  defp privacy_requests!(count) do
    requester = Clubeira.Factory.insert(:user)
    scope = ActorScope.new!(requester.id, Ecto.UUID.generate(version: 7))

    assert {:ok, _profile} =
             People.put_self_profile(scope, %{"display_name" => "Titular da solicitação"})

    Enum.map(1..count, fn _index ->
      assert {:ok, %{request: request}} =
               Privacy.submit_request(scope, %{
                 "client_request_id" => Ecto.UUID.generate(version: 7),
                 "request_type" => "access"
               })

      request
    end)
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
