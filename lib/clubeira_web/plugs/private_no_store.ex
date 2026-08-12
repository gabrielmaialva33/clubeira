defmodule ClubeiraWeb.Plugs.PrivateNoStore do
  @moduledoc false

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(options), do: options

  @impl true
  def call(conn, _options), do: put_resp_header(conn, "cache-control", "private, no-store")
end
