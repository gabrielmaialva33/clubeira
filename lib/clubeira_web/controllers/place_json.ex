defmodule ClubeiraWeb.PlaceJSON do
  @moduledoc false

  def index(%{directory: directory}) do
    %{
      data: %{
        polo: directory.polo,
        places: Enum.map(directory.places, &place_data/1)
      },
      meta: %{page: directory.page}
    }
  end

  defp place_data(place) do
    update_in(place, [:address], fn address ->
      address
      |> Map.update!(:latitude, &decimal_to_string/1)
      |> Map.update!(:longitude, &decimal_to_string/1)
    end)
  end

  defp decimal_to_string(nil), do: nil
  defp decimal_to_string(value), do: Decimal.to_string(value, :normal)
end
