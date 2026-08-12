defmodule Clubeira.UnavailablePublicPolosReader do
  @moduledoc false

  def list_public(_params), do: {:error, :temporarily_unavailable}
end
