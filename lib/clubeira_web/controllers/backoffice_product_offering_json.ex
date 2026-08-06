defmodule ClubeiraWeb.BackofficeProductOfferingJSON do
  @moduledoc false

  def create(%{result: result}), do: %{data: result}
end
