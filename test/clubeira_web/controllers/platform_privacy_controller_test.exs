defmodule ClubeiraWeb.PlatformPrivacyControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.People
  alias Clubeira.Privacy
  alias Clubeira.PrivacyFixtures
  alias Clubeira.Tenancy.ActorScope

  @password "uma-senha-de-plataforma-muito-forte"

  setup do
    requester = authenticated_user!()
    requester_scope = ActorScope.new!(requester.user.id, uuid7())

    assert {:ok, _profile} =
             People.put_self_profile(requester_scope, %{"display_name" => "Titular"})

    assert {:ok, %{request: request}} =
             Privacy.submit_request(requester_scope, %{
               "client_request_id" => uuid7(),
               "request_type" => "access"
             })

    officer = authenticated_user!()
    PrivacyFixtures.privacy_officer!(officer.user)

    unauthorized = authenticated_user!()
    notice = PrivacyFixtures.consent_purpose!()

    %{notice: notice, officer: officer, request: request, unauthorized: unauthorized}
  end

  test "privacy officers operate purposes and request lifecycle through authenticated APIs", %{
    conn: conn,
    notice: notice,
    officer: officer,
    request: request
  } do
    purpose_code = "product-research-#{uuid7()}"

    attributes = %{
      "name" => "Pesquisa de produto",
      "legal_basis" => "consent",
      "legal_document_version_id" => notice.version_id,
      "status" => "active"
    }

    first_purpose =
      conn
      |> bearer(officer.token)
      |> put(~p"/api/v1/platform/privacy/processing-purposes/#{purpose_code}", attributes)
      |> json_response(200)

    assert %{
             "data" => %{
               "code" => ^purpose_code,
               "name" => "Pesquisa de produto",
               "legal_basis" => "consent",
               "legal_document_version_id" => legal_version_id,
               "status" => "active"
             }
           } = first_purpose

    assert legal_version_id == notice.version_id

    assert conn
           |> recycle()
           |> bearer(officer.token)
           |> put(~p"/api/v1/platform/privacy/processing-purposes/#{purpose_code}", attributes)
           |> json_response(200) == first_purpose

    assert %{"data" => purposes} =
             conn
             |> recycle()
             |> bearer(officer.token)
             |> get(~p"/api/v1/platform/privacy/processing-purposes")
             |> json_response(200)

    assert Enum.any?(purposes, &(&1["code"] == purpose_code))

    assert %{
             "data" => [%{"id" => request_id, "status" => "received"}],
             "page" => %{"has_more" => false, "limit" => 20, "next_cursor" => nil}
           } =
             conn
             |> recycle()
             |> bearer(officer.token)
             |> get(~p"/api/v1/platform/privacy/requests?status=received")
             |> json_response(200)

    assert request_id == request.id

    assert %{"data" => %{"id" => ^request_id, "status" => "in_progress"}} =
             conn
             |> recycle()
             |> bearer(officer.token)
             |> post(~p"/api/v1/platform/privacy/requests/#{request_id}/transitions", %{
               "action" => "start_processing",
               "expected_status" => "received"
             })
             |> json_response(200)
  end

  test "ordinary authenticated users cannot operate platform privacy", %{
    conn: conn,
    unauthorized: unauthorized
  } do
    assert %{"errors" => %{"code" => "platform_privacy_officer_required"}} =
             conn
             |> bearer(unauthorized.token)
             |> get(~p"/api/v1/platform/privacy/requests")
             |> json_response(403)
  end

  defp authenticated_user! do
    user = Clubeira.Factory.insert(:user)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    %{token: session.token, user: user}
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")
  defp uuid7, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
