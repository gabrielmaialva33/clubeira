defmodule ClubeiraWeb.Plugs.LoginRateLimitTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Clubeira.Security.LoginRateLimiter
  alias ClubeiraWeb.Plugs.LoginRateLimit

  defmodule CaptureLimiter do
    @moduledoc false

    def hit(key, _scale, _limit) do
      send(self(), {:rate_limit_key, key})
      {:allow, 1}
    end
  end

  defmodule DenyLimiter do
    @moduledoc false

    def hit(key, _scale, _limit) do
      send(self(), {:denied_rate_limit_key, key})
      {:deny, 1_500}
    end
  end

  @limits [
    global: [scale_ms: 1_000, limit: 10],
    ip: [scale_ms: 60_000, limit: 10],
    identity: [scale_ms: 900_000, limit: 10]
  ]

  test "uses only fingerprints in limiter keys" do
    email = " Member@Example.Test "

    [
      {:login, :ip, ip_fingerprint},
      {:login, :identity, identity_fingerprint},
      {:login, :global}
    ] = captured_keys(login_conn(email))

    assert byte_size(ip_fingerprint) == 32
    assert byte_size(identity_fingerprint) == 32
    refute inspect(identity_fingerprint) =~ String.trim(email)
  end

  test "returns a retryable JSON response before authentication" do
    response =
      "member@example.test"
      |> login_conn()
      |> LoginRateLimit.call(config: [limiter: DenyLimiter, limits: @limits])

    assert response.halted
    assert response.status == 429
    assert get_resp_header(response, "retry-after") == ["2"]

    assert Jason.decode!(response.resp_body) == %{
             "errors" => %{"detail" => "Too Many Requests"}
           }

    assert_receive {:denied_rate_limit_key, {:login, :ip, _fingerprint}}
    refute_receive {:denied_rate_limit_key, _other_key}
  end

  test "groups IPv6 peers by /64 and normalizes IPv4-mapped addresses" do
    first_ipv6 = {0x2001, 0x0DB8, 0xCAFE, 0x1234, 1, 2, 3, 4}
    same_network = {0x2001, 0x0DB8, 0xCAFE, 0x1234, 5, 6, 7, 8}
    other_network = {0x2001, 0x0DB8, 0xCAFE, 0x5678, 1, 2, 3, 4}

    assert ip_fingerprint(first_ipv6) == ip_fingerprint(same_network)
    refute ip_fingerprint(first_ipv6) == ip_fingerprint(other_network)

    ipv4 = {192, 0, 2, 1}
    ipv4_mapped = {0, 0, 0, 0, 0, 65_535, 0xC000, 0x0201}
    assert ip_fingerprint(ipv4) == ip_fingerprint(ipv4_mapped)
  end

  test "the supervised Hammer limiter enforces a real bucket" do
    key = {:test_login_limit, System.unique_integer([:positive, :monotonic])}
    assert {:allow, 1} = LoginRateLimiter.hit(key, 60_000, 1)
    assert {:deny, retry_after_ms} = LoginRateLimiter.hit(key, 60_000, 1)
    assert retry_after_ms > 0
  end

  test "the supervised limiter anchors each window to its first hit" do
    now = System.system_time(:millisecond)
    scale = Enum.max_by(60_000..60_100, &rem(now, &1))
    key = {:test_per_key_window, System.unique_integer([:positive, :monotonic])}
    before_hit = System.system_time(:millisecond)

    assert {:allow, 1} = LoginRateLimiter.hit(key, scale, 1)

    after_hit = System.system_time(:millisecond)
    expires_at = LoginRateLimiter.expires_at(key, scale)
    assert expires_at >= before_hit + scale
    assert expires_at <= after_hit + scale
  end

  defp captured_keys(conn) do
    refute LoginRateLimit.call(conn, config: [limiter: CaptureLimiter, limits: @limits]).halted

    for _index <- 1..3 do
      assert_receive {:rate_limit_key, key}
      key
    end
  end

  defp ip_fingerprint(remote_ip) do
    [{:login, :ip, fingerprint} | _other_keys] =
      "member@example.test"
      |> login_conn()
      |> Map.put(:remote_ip, remote_ip)
      |> captured_keys()

    fingerprint
  end

  defp login_conn(email) do
    conn(:post, "/api/v1/auth/sessions")
    |> Map.put(:body_params, %{"email" => email})
  end
end
