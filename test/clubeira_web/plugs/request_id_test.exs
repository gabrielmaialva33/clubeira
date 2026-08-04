defmodule ClubeiraWeb.Plugs.RequestIdTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ClubeiraWeb.Plugs.RequestId

  test "assigns one UUID to the request, response, and logger metadata" do
    conn = conn(:get, "/") |> RequestId.call(RequestId.init([]))

    assert {:ok, request_id} = Ecto.UUID.cast(conn.assigns.request_id)
    assert get_resp_header(conn, "x-request-id") == [request_id]
    assert Logger.metadata()[:request_id] == request_id
  end

  test "never trusts an external request ID as the internal audit identifier" do
    external = Ecto.UUID.generate(version: 7)

    conn =
      conn(:get, "/")
      |> put_req_header("x-request-id", external)
      |> RequestId.call(RequestId.init([]))

    refute conn.assigns.request_id == external
    assert {:ok, internal} = Ecto.UUID.cast(conn.assigns.request_id)
    assert get_resp_header(conn, "x-request-id") == [internal]
  end
end
