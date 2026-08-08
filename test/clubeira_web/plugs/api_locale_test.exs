defmodule ClubeiraWeb.Plugs.ApiLocaleTest do
  use ClubeiraWeb.ConnCase

  alias ClubeiraWeb.Plugs.ApiLocale

  test "the API translates errors using the preferred supported language", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept-language", "en;q=0.4, pt-BR;q=0.9")
      |> get(~p"/api/v1/legal/registration?locale=invalid_locale")

    assert json_response(conn, 400) == %{
             "errors" => %{"detail" => "Requisição inválida"}
           }

    assert get_resp_header(conn, "content-language") == ["pt-BR"]
    assert "accept-language" in vary_values(conn)
  end

  test "the API falls back to English for an unsupported language", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept-language", "fr-FR")
      |> get(~p"/api/v1/legal/registration?locale=invalid_locale")

    assert json_response(conn, 400) == %{
             "errors" => %{"detail" => "Bad Request"}
           }

    assert get_resp_header(conn, "content-language") == ["en"]
  end

  test "preserves existing Vary dimensions", %{conn: conn} do
    conn =
      conn
      |> put_resp_header("vary", "accept-encoding")
      |> ApiLocale.call([])

    assert Enum.sort(vary_values(conn)) == ["accept-encoding", "accept-language"]
  end

  defp vary_values(conn) do
    conn
    |> get_resp_header("vary")
    |> Enum.flat_map(&String.split(&1, ",", trim: true))
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
  end
end
