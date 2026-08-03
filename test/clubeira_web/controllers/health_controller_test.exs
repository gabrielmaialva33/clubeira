defmodule ClubeiraWeb.HealthControllerTest do
  use ClubeiraWeb.ConnCase

  test "GET /health", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert json_response(conn, 200) == %{
             "service" => "clubeira",
             "status" => "ok"
           }

    assert [content_security_policy] = get_resp_header(conn, "content-security-policy")
    assert content_security_policy =~ "connect-src 'self'"
    refute content_security_policy =~ " ws:"
    refute content_security_policy =~ " wss:"
  end
end
