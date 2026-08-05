defmodule ClubeiraWeb.RedemptionGrantJSON do
  @moduledoc false

  def create(%{grant: grant}) do
    %{
      data: %{
        grant: grant.token,
        expires_at: DateTime.to_iso8601(grant.expires_at)
      }
    }
  end
end
