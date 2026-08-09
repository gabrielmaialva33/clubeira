defmodule Clubeira.Reviews.MediaVerifiers.Http do
  @moduledoc """
  Verifies object metadata through a trusted storage-control HTTP endpoint.
  """

  @behaviour Clubeira.Reviews.MediaVerifier

  @impl true
  def verify(storage_key) when is_binary(storage_key) do
    with {:ok, config} <- configuration(),
         {:ok, response} <-
           Req.get(
             config.verification_url,
             Keyword.merge(config.req_options,
               params: [key: storage_key],
               headers: authorization_headers(config.bearer_token),
               redirect: false,
               receive_timeout: 5_000
             )
           ),
         200 <- response.status,
         %{} = body <- response.body,
         true <- body["immutable"] == true,
         {:ok, digest} <- decode_digest(body["sha256"]) do
      {:ok,
       %{
         content_type: body["content_type"],
         content_sha256: digest,
         size_bytes: body["size_bytes"],
         width: body["width"],
         height: body["height"],
         duration_ms: body["duration_ms"]
       }}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _invalid_or_unavailable -> {:error, :media_not_verified}
    end
  end

  def verify(_storage_key), do: {:error, :media_not_verified}

  @impl true
  def public_url(storage_key) when is_binary(storage_key) do
    with {:ok, config} <- configuration() do
      {:ok, config.public_base_url <> "/" <> encode_path(storage_key)}
    end
  end

  def public_url(_storage_key), do: {:error, :media_not_found}

  defp configuration do
    config = Application.get_env(:clubeira, __MODULE__, [])
    verification_url = Keyword.get(config, :verification_url)
    public_base_url = Keyword.get(config, :public_base_url)

    if valid_http_url?(verification_url) and valid_http_url?(public_base_url) do
      {:ok,
       %{
         verification_url: verification_url,
         public_base_url: String.trim_trailing(public_base_url, "/"),
         bearer_token: Keyword.get(config, :bearer_token),
         req_options: Keyword.get(config, :req_options, [])
       }}
    else
      {:error, :media_storage_unavailable}
    end
  end

  defp valid_http_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        true

      _invalid ->
        false
    end
  end

  defp valid_http_url?(_url), do: false

  defp authorization_headers(nil), do: []
  defp authorization_headers(token), do: [{"authorization", "Bearer #{token}"}]

  defp decode_digest(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, digest} when byte_size(digest) == 32 -> {:ok, digest}
      _invalid -> {:error, :media_not_verified}
    end
  end

  defp decode_digest(_value), do: {:error, :media_not_verified}

  defp encode_path(storage_key) do
    storage_key
    |> String.split("/", trim: true)
    |> Enum.map_join("/", &URI.encode/1)
  end
end
