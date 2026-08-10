defmodule ClubeiraWeb.Backoffice.PlaceLifecycleJSON do
  @moduledoc false

  def create(%{result: result}), do: %{data: result}
end
