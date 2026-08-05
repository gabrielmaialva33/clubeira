defmodule Clubeira.Outbox.Adapters.Http do
  @moduledoc """
  Delivers outbox envelopes to one HTTPS consumer.

  The receiver must deduplicate by `x-clubeira-event-id`. Signatures cover the
  exact request body as `HMAC-SHA256(secret, timestamp <> "." <> body)`.
  """

  @behaviour Clubeira.Outbox.Adapter

  alias Clubeira.Events.OutboxMessage

  @minimum_secret_bytes 32
  @default_receive_timeout 10_000

  @impl true
  def publish(%OutboxMessage{} = message, options) when is_list(options) do
    %{url: url, secret: secret, receive_timeout: receive_timeout} = config!(options)
    body = Jason.encode!(message.payload)
    timestamp = Integer.to_string(System.system_time(:second))
    signature = signature(secret, timestamp, body)

    request_options =
      options
      |> Keyword.get(:req_options, [])
      |> Keyword.merge(
        url: url,
        method: :post,
        body: body,
        headers: [
          {"content-type", "application/json"},
          {"x-clubeira-event-id", message.id},
          {"x-clubeira-topic", message.topic},
          {"x-clubeira-message-key", message.message_key},
          {"x-clubeira-timestamp", timestamp},
          {"x-clubeira-signature", "v1=#{signature}"}
        ],
        retry: false,
        redirect: false,
        receive_timeout: receive_timeout
      )

    case Req.request(request_options) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, %Req.TransportError{reason: reason}} when is_atom(reason) ->
        {:error, {:transport, reason}}

      {:error, _reason} ->
        {:error, :request_failed}
    end
  end

  defp signature(secret, timestamp, body) do
    :crypto.mac(:hmac, :sha256, secret, timestamp <> "." <> body)
    |> Base.encode16(case: :lower)
  end

  defp config!(options) do
    url = Keyword.fetch!(options, :url)
    secret = Keyword.fetch!(options, :secret)
    receive_timeout = Keyword.get(options, :receive_timeout, @default_receive_timeout)

    unless valid_https_url?(url) do
      raise ArgumentError, "outbox HTTP adapter URL must be an absolute HTTPS URL"
    end

    unless is_binary(secret) and byte_size(secret) >= @minimum_secret_bytes do
      raise ArgumentError, "outbox HTTP adapter secret must contain at least 32 bytes"
    end

    unless is_integer(receive_timeout) and receive_timeout > 0 do
      raise ArgumentError, "outbox HTTP adapter receive_timeout must be a positive integer"
    end

    %{url: url, secret: secret, receive_timeout: receive_timeout}
  end

  defp valid_https_url?(url) when is_binary(url) and byte_size(url) <= 2_048 do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil}}
      when is_binary(host) and host != "" ->
        true

      _invalid ->
        false
    end
  end

  defp valid_https_url?(_url), do: false
end
