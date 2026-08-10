defmodule ClubeiraWeb.Backoffice.ValidationCredentialRevocationJSON do
  @moduledoc false

  def create(%{result: result}), do: %{data: result}
end
