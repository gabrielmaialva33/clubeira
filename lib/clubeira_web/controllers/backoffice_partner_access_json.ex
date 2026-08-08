defmodule ClubeiraWeb.BackofficePartnerAccessJSON do
  @moduledoc false

  def create(%{result: result}), do: %{data: result}
  def revoke(%{result: result}), do: %{data: result}
end
