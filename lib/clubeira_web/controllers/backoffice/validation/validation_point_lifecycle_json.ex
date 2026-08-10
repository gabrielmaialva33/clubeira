defmodule ClubeiraWeb.Backoffice.ValidationPointLifecycleJSON do
  @moduledoc false

  def create(%{result: result}), do: %{data: result}
end
