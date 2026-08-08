defmodule ClubeiraWeb.BackofficePlaceLifecycleJSON do
  @moduledoc false

  def create(%{result: result}), do: %{data: result}
end
