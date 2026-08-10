defmodule ClubeiraWeb.Platform.SubscriptionJSON do
  @moduledoc false

  def create(%{result: result}) do
    %{data: %{provider: result.provider, subscription: subscription_data(result.subscription)}}
  end

  defp subscription_data(subscription) do
    %{
      id: subscription.id,
      status: subscription.status,
      platform_plan_version_id: subscription.platform_plan_version_id,
      platform_price_id: subscription.platform_price_id,
      next_action: subscription.next_action,
      next_charge_at: datetime(subscription.next_charge_at),
      current_period: range(subscription.current_period),
      inserted_at: DateTime.to_iso8601(subscription.inserted_at),
      updated_at: DateTime.to_iso8601(subscription.updated_at)
    }
  end

  defp datetime(nil), do: nil
  defp datetime(value), do: DateTime.to_iso8601(value)
  defp range(nil), do: nil

  defp range(value) do
    %{starts_at: DateTime.to_iso8601(value.lower), ends_at: DateTime.to_iso8601(value.upper)}
  end
end
