defmodule ClubeiraWeb.RedemptionConfirmationJSON do
  @moduledoc false

  def create(%{redemption: redemption}) do
    %{
      data: %{
        id: redemption.id,
        entitlement_allocation_id: redemption.entitlement_allocation_id,
        validation_point_id: redemption.validation_point_id,
        units: redemption.units,
        redeemed_at: DateTime.to_iso8601(redemption.redeemed_at)
      }
    }
  end
end
