defmodule ClubeiraWeb.Plugs.ApiAuth do
  @moduledoc """
  Authenticates opaque bearer sessions and assigns the server-derived account scope.
  """

  import Plug.Conn

  alias Clubeira.Accounts
  alias ClubeiraWeb.ErrorJSON

  @behaviour Plug

  @impl true
  def init(options), do: options

  @impl true
  def call(conn, _options) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, scope} <- Accounts.fetch_scope_by_api_token(token) do
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> assign(:current_account_scope, scope)
    else
      _invalid -> unauthorized(conn)
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      [authorization] -> parse_authorization(authorization)
      _missing_or_ambiguous -> :error
    end
  end

  defp parse_authorization(authorization) when byte_size(authorization) <= 256 do
    case String.split(String.trim(authorization), ~r/\s+/, parts: 2) do
      [scheme, token] when token != "" ->
        if String.downcase(scheme) == "bearer", do: {:ok, token}, else: :error

      _invalid ->
        :error
    end
  end

  defp parse_authorization(_authorization), do: :error

  defp unauthorized(conn) do
    body = Jason.encode_to_iodata!(ErrorJSON.render("401.json", %{}))

    conn
    |> put_resp_header("www-authenticate", ~s(Bearer realm="clubeira", error="invalid_token"))
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(:unauthorized, body)
    |> halt()
  end
end
