defmodule ClubeiraWeb.BackofficeBenefitOfferJSON do
  @moduledoc false

  def create(%{result: result}), do: %{data: result}

  def index(%{benefit_offers: benefit_offers, page: page}) do
    %{
      data: Enum.map(benefit_offers, &benefit_offer_data/1),
      meta: %{count: length(benefit_offers), page: page}
    }
  end

  defp benefit_offer_data(offer) do
    %{
      id: offer.id,
      code: offer.code,
      name: offer.name,
      benefit_kind: offer.benefit_kind,
      status: offer.status,
      recorded_at: datetime_to_string(offer.recorded_at),
      latest_version: version_data(offer.latest_version)
    }
  end

  defp version_data(nil), do: nil

  defp version_data(version) do
    %Postgrex.Range{lower: effective_from, upper: effective_until} = version.effective_during

    %{
      id: version.id,
      version: version.version,
      title: version.title,
      description: version.description,
      terms: version.terms,
      redemption_instructions: version.redemption_instructions,
      status: version.status,
      published_at: datetime_to_string(version.published_at),
      effective_from: datetime_to_string(effective_from),
      effective_until: range_bound_to_string(effective_until),
      benefit: %{
        percentage: decimal_to_string(version.percentage_value),
        amount: decimal_to_string(version.amount_value),
        currency: version.currency
      },
      places: version.places
    }
  end

  defp decimal_to_string(nil), do: nil
  defp decimal_to_string(value), do: Decimal.to_string(value, :normal)

  defp datetime_to_string(nil), do: nil
  defp datetime_to_string(value), do: DateTime.to_iso8601(value)

  defp range_bound_to_string(:unbound), do: nil
  defp range_bound_to_string(value), do: datetime_to_string(value)
end
