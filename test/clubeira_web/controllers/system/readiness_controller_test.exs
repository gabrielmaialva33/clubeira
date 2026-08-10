defmodule ClubeiraWeb.System.ReadinessControllerTest do
  use ClubeiraWeb.ConnCase

  test "GET /ready reports a usable runtime database", %{conn: conn} do
    conn = get(conn, ~p"/ready")

    assert json_response(conn, 200) == %{
             "service" => "clubeira",
             "status" => "ready"
           }

    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "GET /ready fails closed without leaking database details", %{conn: conn} do
    previous_dynamic_repo = Clubeira.Repo.get_dynamic_repo()
    Clubeira.Repo.put_dynamic_repo(:unavailable_readiness_database)

    on_exit(fn -> Clubeira.Repo.put_dynamic_repo(previous_dynamic_repo) end)

    readiness_conn = get(conn, ~p"/ready")

    assert json_response(readiness_conn, 503) == %{
             "service" => "clubeira",
             "status" => "not_ready"
           }

    assert get_resp_header(readiness_conn, "cache-control") == ["no-store"]
    refute readiness_conn.resp_body =~ "unavailable_readiness_database"

    health_conn = get(build_conn(), ~p"/health")
    assert json_response(health_conn, 200)["status"] == "ok"
  end
end
