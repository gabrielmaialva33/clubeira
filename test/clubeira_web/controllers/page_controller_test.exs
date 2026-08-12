defmodule ClubeiraWeb.PageControllerTest do
  use ClubeiraWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/explorar"
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
  end
end
