defmodule Clubeira.Outbox.Adapters.HttpTest do
  use ExUnit.Case, async: true

  import Plug.Conn

  alias Clubeira.Events.OutboxMessage
  alias Clubeira.Outbox.Adapters.Http

  @secret "test-only-outbox-secret-with-32-bytes"

  test "publishes the event envelope with an idempotency key and an HMAC signature" do
    message = message()

    Req.Test.expect(Http, fn request ->
      assert request.method == "POST"
      assert request.request_path == "/events/clubeira"
      assert get_req_header(request, "content-type") == ["application/json"]
      assert get_req_header(request, "x-clubeira-event-id") == [message.id]
      assert get_req_header(request, "x-clubeira-topic") == [message.topic]
      assert get_req_header(request, "x-clubeira-message-key") == [message.message_key]

      assert [timestamp] = get_req_header(request, "x-clubeira-timestamp")
      assert {unix_timestamp, ""} = Integer.parse(timestamp)
      assert abs(System.system_time(:second) - unix_timestamp) <= 5

      {:ok, body, request} = read_body(request)
      assert Jason.decode!(body) == message.payload

      expected_signature =
        :crypto.mac(:hmac, :sha256, @secret, timestamp <> "." <> body)
        |> Base.encode16(case: :lower)

      assert get_req_header(request, "x-clubeira-signature") == ["v1=#{expected_signature}"]

      send_resp(request, 202, "accepted")
    end)

    assert :ok = Http.publish(message, options())
  end

  test "returns only the status when the consumer rejects a message" do
    Req.Test.expect(Http, fn request ->
      send_resp(request, 503, "sensitive upstream body")
    end)

    assert {:error, {:http_status, 503}} = Http.publish(message(), options())
  end

  test "normalizes transport failures without leaking request configuration" do
    Req.Test.expect(Http, fn request ->
      Req.Test.transport_error(request, :timeout)
    end)

    assert {:error, {:transport, :timeout}} = Http.publish(message(), options())
  end

  test "rejects unsafe destinations before making a request" do
    invalid_urls = [
      "http://events.example.test/events",
      "https://user:password@events.example.test/events",
      "https:///events",
      "not a url",
      String.duplicate("x", 2_049),
      nil
    ]

    for url <- invalid_urls do
      assert_raise ArgumentError, ~r/absolute HTTPS URL/, fn ->
        Http.publish(message(), Keyword.put(options(), :url, url))
      end
    end
  end

  test "requires a strong secret and a positive receive timeout" do
    for secret <- [nil, "short", String.duplicate("x", 31)] do
      assert_raise ArgumentError, ~r/secret must contain at least 32 bytes/, fn ->
        Http.publish(message(), Keyword.put(options(), :secret, secret))
      end
    end

    for timeout <- [nil, 0, -1, "1000"] do
      assert_raise ArgumentError, ~r/receive_timeout must be a positive integer/, fn ->
        Http.publish(message(), Keyword.put(options(), :receive_timeout, timeout))
      end
    end
  end

  defp options do
    [
      url: "https://events.example.test/events/clubeira",
      secret: @secret,
      req_options: [plug: {Req.Test, Http}]
    ]
  end

  defp message do
    event_id = Ecto.UUID.generate(version: 7)

    %OutboxMessage{
      id: event_id,
      domain_event_id: event_id,
      topic: "billing.orders.placed",
      message_key: "order-123",
      payload: %{
        "event_id" => event_id,
        "event_type" => "billing.order_placed",
        "polo_id" => Ecto.UUID.generate(version: 7),
        "occurred_at" => "2026-08-05T12:00:00.000000Z",
        "data" => %{"order_id" => "order-123"}
      },
      status: "publishing",
      attempt_count: 1,
      available_at: ~U[2026-08-05 12:00:00.000000Z],
      locked_at: ~U[2026-08-05 12:00:01.000000Z],
      locked_by: "test-worker",
      inserted_at: ~U[2026-08-05 12:00:00.000000Z],
      updated_at: ~U[2026-08-05 12:00:01.000000Z]
    }
  end
end
