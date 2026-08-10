defmodule ClubeiraWeb.Backoffice.PlaceProfileJSON do
  @moduledoc false

  def update(%{result: result}), do: %{data: result}
end
