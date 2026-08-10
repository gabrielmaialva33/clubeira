defmodule ClubeiraWeb.Plugs.RawBodyTest do
  use ExUnit.Case, async: true

  alias ClubeiraWeb.Plugs.RawBody

  test "retains the exact webhook body for provider signature verification" do
    body = ~s({"data":{"id":"evt_123"},"amount":100})
    conn = Plug.Test.conn(:post, "/api/v1/webhooks/stripe/account", body)

    assert {:ok, ^body, conn} = RawBody.read_body(conn, [])
    assert RawBody.get(conn) == body
  end

  test "does not duplicate ordinary API request bodies" do
    body = ~s({"email":"member@example.com"})
    conn = Plug.Test.conn(:post, "/api/v1/auth/login", body)

    assert {:ok, ^body, conn} = RawBody.read_body(conn, [])
    assert RawBody.get(conn) == ""
  end

  test "retains all chunks in their original order" do
    body = ~s({"data":{"id":"evt_123"},"amount":100})
    conn = Plug.Test.conn(:post, "/api/v1/webhooks/stripe/account", body)

    assert {:more, first, conn} = RawBody.read_body(conn, length: 12)
    assert {:more, second, conn} = RawBody.read_body(conn, length: 12)
    assert {:more, third, conn} = RawBody.read_body(conn, length: 12)
    assert {:ok, last, conn} = RawBody.read_body(conn, length: 12)

    assert RawBody.get(conn) == first <> second <> third <> last
    assert RawBody.get(conn) == body
  end
end
