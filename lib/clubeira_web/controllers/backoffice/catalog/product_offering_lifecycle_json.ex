defmodule ClubeiraWeb.Backoffice.ProductOfferingLifecycleJSON do
  @moduledoc false

  def create(%{result: result}), do: %{data: result}
end
