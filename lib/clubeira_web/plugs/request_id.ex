defmodule ClubeiraWeb.Plugs.RequestId do
  @moduledoc """
  Uses a UUID request identifier that can be persisted in audit tables unchanged.
  """

  import Plug.Conn

  @behaviour Plug
  @default_header "x-request-id"

  @impl true
  def init(options), do: Keyword.get(options, :http_header, @default_header)

  @impl true
  def call(conn, header) do
    request_id = generate()
    Logger.metadata(request_id: request_id)

    conn
    |> assign(:request_id, request_id)
    |> put_resp_header(header, request_id)
  end

  defp generate, do: Ecto.UUID.generate(version: 7, precision: :monotonic)
end
