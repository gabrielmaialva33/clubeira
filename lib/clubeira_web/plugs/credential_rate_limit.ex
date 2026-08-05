defmodule ClubeiraWeb.Plugs.CredentialRateLimit do
  @moduledoc """
  Applies action-specific global, network-peer, and identity limits before
  password hashing or verification executes.
  """

  import Plug.Conn

  alias ClubeiraWeb.ErrorJSON

  @behaviour Plug

  @actions [:login, :registration, :password_reset_request, :password_reset]

  @impl true
  def init(options) do
    action = Keyword.get(options, :action, :login)

    if action in @actions do
      Keyword.put(options, :action, action)
    else
      raise ArgumentError, "unsupported credential rate-limit action: #{inspect(action)}"
    end
  end

  @impl true
  def call(conn, options) do
    action = Keyword.get(options, :action, :login)
    config = Keyword.get_lazy(options, :config, &runtime_config!/0)
    limiter = Keyword.fetch!(config, :limiter)
    limits = config |> Keyword.fetch!(:limits) |> Keyword.fetch!(action)

    case first_denied_limit(limiter, action, conn, limits) do
      nil -> conn
      {dimension, retry_after_ms} -> reject(conn, action, dimension, retry_after_ms)
    end
  end

  defp first_denied_limit(limiter, action, conn, limits) do
    conn
    |> limit_keys(action)
    |> Enum.find_value(fn {dimension, key} ->
      limit = Keyword.fetch!(limits, dimension)

      case limiter.hit(key, Keyword.fetch!(limit, :scale_ms), Keyword.fetch!(limit, :limit)) do
        {:allow, _count} -> nil
        {:deny, retry_after_ms} -> {dimension, retry_after_ms}
      end
    end)
  end

  defp limit_keys(conn, action) do
    [
      {:ip, {action, :ip, network_fingerprint(conn.remote_ip)}},
      {:identity, {action, :identity, fingerprint(credential_identity(conn, action))}},
      {:global, {action, :global}}
    ]
  end

  defp network_fingerprint({first, second, third, fourth}) do
    fingerprint(:erlang.term_to_binary({:ipv4, first, second, third, fourth}))
  end

  defp network_fingerprint({0, 0, 0, 0, 0, 65_535, high, low}) do
    network_fingerprint({
      div(high, 256),
      rem(high, 256),
      div(low, 256),
      rem(low, 256)
    })
  end

  defp network_fingerprint({first, second, third, fourth, _, _, _, _}) do
    fingerprint(:erlang.term_to_binary({:ipv6_64, first, second, third, fourth}))
  end

  defp credential_identity(%Plug.Conn{body_params: %{"token" => token}}, :password_reset)
       when is_binary(token) and byte_size(token) <= 128,
       do: token

  defp credential_identity(%Plug.Conn{body_params: %{"email" => email}}, _action)
       when is_binary(email) do
    email |> String.trim() |> String.downcase()
  end

  defp credential_identity(_conn, _action), do: ""

  defp fingerprint(value), do: :crypto.hash(:sha256, value)

  defp reject(conn, action, dimension, retry_after_ms) do
    :telemetry.execute(
      [:clubeira, :security, :credential_rate_limited],
      %{count: 1},
      %{action: action, dimension: dimension}
    )

    retry_after_seconds = max(1, ceil(retry_after_ms / 1_000))

    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
    |> put_resp_content_type("application/json")
    |> send_resp(
      :too_many_requests,
      Jason.encode_to_iodata!(ErrorJSON.render("429.json", %{}))
    )
    |> halt()
  end

  defp runtime_config! do
    Application.fetch_env!(:clubeira, __MODULE__)
  end
end
