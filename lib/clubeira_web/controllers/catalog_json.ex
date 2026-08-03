defmodule ClubeiraWeb.CatalogJSON do
  @moduledoc false

  def show(%{catalog: catalog}) do
    %{
      data: %{
        polo: catalog.polo,
        offers: Enum.map(catalog.offers, &offer_data/1)
      },
      meta: %{page: catalog.page}
    }
  end

  defp offer_data(offer) do
    %{
      offer_id: offer.offer_id,
      offer_version_id: offer.offer_version_id,
      version: offer.version,
      code: offer.code,
      name: offer.name,
      title: offer.title,
      description: offer.description,
      terms: offer.terms,
      redemption_instructions: offer.redemption_instructions,
      benefit: %{
        kind: offer.benefit_kind,
        percentage: decimal_to_string(offer.percentage_value),
        amount: decimal_to_string(offer.amount_value),
        currency: offer.currency
      },
      effective_during: %{
        starts_at: offer.effective_from,
        ends_at: offer.effective_until
      },
      places: offer.places
    }
  end

  defp decimal_to_string(nil), do: nil
  defp decimal_to_string(value), do: Decimal.to_string(value, :normal)
end
