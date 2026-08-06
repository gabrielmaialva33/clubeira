defmodule ClubeiraWeb.BackofficeBenefitOfferJSON do
  @moduledoc false

  def create(%{result: result}), do: %{data: result}
end
