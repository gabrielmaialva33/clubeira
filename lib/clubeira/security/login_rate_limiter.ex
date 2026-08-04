defmodule Clubeira.Security.LoginRateLimiter do
  @moduledoc """
  Per-node admission limiter for authentication requests.

  The local limiter protects each BEAM instance even when an upstream or
  distributed limiter is unavailable. Production ingress remains responsible
  for enforcing a cluster-wide limit.
  """

  use Hammer, backend: :ets, algorithm: :fix_window_per_key
end
