defmodule ClubeiraWeb.PoloJSON do
  @moduledoc false

  def index(%{polos: polos, page: page}) do
    %{
      data: Enum.map(polos, &polo_data/1),
      meta: %{count: length(polos), page: page}
    }
  end

  defp polo_data(polo) do
    %{
      id: polo.id,
      slug: polo.slug,
      name: polo.name,
      timezone: polo.timezone,
      city: %{
        id: polo.city.id,
        name: polo.city.name,
        subdivision_code: polo.city.subdivision_code,
        country_code: polo.city.country_code,
        timezone: polo.city.timezone
      }
    }
  end
end
