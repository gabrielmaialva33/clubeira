defmodule ClubeiraWeb.Backoffice.SubscriptionLifecycleJSON do
  @moduledoc false

  def create(%{result: result}), do: %{data: result}
end
