defmodule ClubeiraWeb.Webhooks.RequestEnvelopeTest do
  use ExUnit.Case, async: true

  alias ClubeiraWeb.Plugs.RawBody
  alias ClubeiraWeb.Webhooks.RequestEnvelope

  test "preserves raw body, decoded inputs and every provider header" do
    raw_body = ~s({"id":"evt_123","amount":100})

    conn =
      :post
      |> Plug.Test.conn("/api/v1/webhooks/stripe/account?livemode=true", raw_body)
      |> Map.put(:body_params, %{"id" => "evt_123", "amount" => 100})
      |> Map.put(:query_params, %{"livemode" => "true"})
      |> Map.update!(:req_headers, fn headers ->
        [
          {"stripe-signature", "t=1,v1=first"},
          {"stripe-signature", "t=1,v1=second"}
          | headers
        ]
      end)

    assert {:ok, ^raw_body, conn} = RawBody.read_body(conn, [])

    assert %{
             body_params: %{"id" => "evt_123", "amount" => 100},
             headers: %{
               "stripe-signature" => ["t=1,v1=first", "t=1,v1=second"]
             },
             query_params: %{"livemode" => "true"},
             raw_body: ^raw_body
           } = RequestEnvelope.build(conn)
  end
end
