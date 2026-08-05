defmodule ClubeiraWeb.RedemptionJSON do
  @moduledoc false

  def index(%{redemptions: redemptions, page: page}) do
    %{
      data: Enum.map(redemptions, &redemption_data/1),
      meta: %{count: length(redemptions), page: page}
    }
  end

  defp redemption_data(redemption) do
    %{
      id: redemption.id,
      polo_place_id: redemption.polo_place_id,
      units: redemption.units,
      redeemed_at: DateTime.to_iso8601(redemption.redeemed_at),
      place: redemption.place,
      benefit: redemption.benefit,
      review: review_data(redemption.review)
    }
  end

  defp review_data(nil), do: nil

  defp review_data(review) do
    Map.update!(review, :submitted_at, &DateTime.to_iso8601/1)
  end
end
