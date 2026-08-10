defmodule ClubeiraWeb.Webhooks.RequestEnvelope do
  @moduledoc false

  alias ClubeiraWeb.Plugs.RawBody
  alias Plug.Conn

  @spec build(Conn.t()) :: Clubeira.Billing.Gateways.webhook_envelope()
  def build(%Conn{} = conn) do
    %{
      body_params: conn.body_params,
      headers: Enum.group_by(conn.req_headers, &elem(&1, 0), &elem(&1, 1)),
      query_params: conn.query_params,
      raw_body: RawBody.get(conn)
    }
  end
end
