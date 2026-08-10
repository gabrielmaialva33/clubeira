defmodule ClubeiraWeb.System.ApiDocsControllerTest do
  use ClubeiraWeb.ConnCase, async: true

  test "GET /api/docs renders Redoc against the published OpenAPI bundle", %{conn: conn} do
    conn = get(conn, "/api/docs")

    assert html_response(conn, 200) =~ ~s(<redoc spec-url="/openapi/v1.json")

    assert get_resp_header(conn, "content-security-policy") == [
             "default-src 'none'; base-uri 'none'; frame-ancestors 'none'; " <>
               "script-src https://cdn.redocly.com; " <>
               "style-src 'unsafe-inline' https://fonts.googleapis.com; " <>
               "font-src data: https://fonts.gstatic.com; img-src data: https:; " <>
               "connect-src 'self'"
           ]
  end

  test "published OpenAPI bundle is served as JSON", %{conn: conn} do
    spec =
      conn
      |> get("/openapi/v1.json")
      |> json_response(200)

    assert spec["openapi"] == "3.1.0"
    assert is_map(spec["paths"])
  end
end
