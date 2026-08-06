defmodule ClubeiraWeb.BackofficeValidationPointJSON do
  @moduledoc false

  def create(%{result: result}), do: %{data: result}
end
