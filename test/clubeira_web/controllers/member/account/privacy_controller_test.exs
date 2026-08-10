defmodule ClubeiraWeb.Member.PrivacyControllerTest do
  use ClubeiraWeb.ConnCase, async: false

  alias Clubeira.Accounts
  alias Clubeira.PrivacyFixtures

  @password "uma-senha-de-privacidade-muito-forte"

  setup %{conn: conn} do
    user = Clubeira.Factory.insert(:user)
    assert {:ok, _credential} = Accounts.set_password(user, @password)
    assert {:ok, session} = Accounts.login(user.email, @password)
    purpose = PrivacyFixtures.consent_purpose!()

    assert conn
           |> bearer(session.token)
           |> put(~p"/api/v1/me/profile", %{"display_name" => "Titular da Privacidade"})
           |> json_response(200)

    %{purpose: purpose, token: session.token}
  end

  test "consent and data-subject request form one authenticated privacy API", %{
    conn: conn,
    purpose: purpose,
    token: token
  } do
    assert %{
             "data" => [
               %{
                 "processing_purpose" => %{
                   "code" => purpose_code,
                   "current_legal_document_version_id" => current_version_id,
                   "legal_basis" => "consent"
                 },
                 "state" => "not_set",
                 "legal_document_version_id" => nil,
                 "occurred_at" => nil
               }
             ]
           } =
             conn
             |> recycle()
             |> bearer(token)
             |> get(~p"/api/v1/me/privacy/consents")
             |> json_response(200)

    assert purpose_code == purpose.code
    assert current_version_id == purpose.version_id

    assert %{
             "data" => %{
               "state" => "granted",
               "legal_document_version_id" => version_id,
               "occurred_at" => occurred_at
             }
           } =
             conn
             |> recycle()
             |> bearer(token)
             |> put(~p"/api/v1/me/privacy/consents/#{purpose.code}", %{
               "state" => "granted",
               "legal_document_version_id" => purpose.version_id
             })
             |> json_response(200)

    assert version_id == purpose.version_id
    assert {:ok, _occurred_at, 0} = DateTime.from_iso8601(occurred_at)

    client_request_id = Ecto.UUID.generate(version: 7)

    first_request_conn =
      conn
      |> recycle()
      |> bearer(token)
      |> post(~p"/api/v1/me/privacy/requests", %{
        "client_request_id" => client_request_id,
        "request_type" => "access"
      })

    assert %{
             "data" => %{
               "id" => request_id,
               "client_request_id" => ^client_request_id,
               "request_type" => "access",
               "status" => "received",
               "events" => [%{"event_type" => "received"}]
             }
           } = json_response(first_request_conn, 201)

    assert conn
           |> recycle()
           |> bearer(token)
           |> post(~p"/api/v1/me/privacy/requests", %{
             "client_request_id" => client_request_id,
             "request_type" => "access"
           })
           |> json_response(200) == json_response(first_request_conn, 201)

    assert %{"data" => [%{"id" => ^request_id}]} =
             conn
             |> recycle()
             |> bearer(token)
             |> get(~p"/api/v1/me/privacy/requests")
             |> json_response(200)
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")
end
