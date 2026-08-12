defmodule ClubeiraWeb.DenyCredentialRateLimiter do
  @moduledoc false

  def hit(_key, _scale_ms, _limit), do: {:deny, 1_500}
end
