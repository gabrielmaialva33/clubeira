defmodule ClubeiraWeb.Plugs.RawBody do
  @moduledoc false

  alias Plug.Conn

  @private_key :clubeira_webhook_raw_body
  @webhook_path_prefix "/api/v1/webhooks/"

  @spec read_body(Conn.t(), keyword()) ::
          {:ok, binary(), Conn.t()}
          | {:more, binary(), Conn.t()}
          | {:error, term()}
  def read_body(%Conn{} = conn, options) do
    case Conn.read_body(conn, options) do
      {:ok, body, conn} -> {:ok, body, maybe_append(conn, body)}
      {:more, body, conn} -> {:more, body, maybe_append(conn, body)}
      {:error, _reason} = error -> error
    end
  end

  @spec get(Conn.t()) :: binary()
  def get(%Conn{} = conn), do: Map.get(conn.private, @private_key, "")

  defp maybe_append(%Conn{request_path: @webhook_path_prefix <> _rest} = conn, body) do
    cached = Map.get(conn.private, @private_key, "")
    Conn.put_private(conn, @private_key, cached <> body)
  end

  defp maybe_append(conn, _body), do: conn
end
