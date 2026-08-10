defmodule ClubeiraWeb.Backoffice.SubscriptionJSON do
  @moduledoc false

  def index(%{subscriptions: subscriptions, page: page}) do
    %{
      data: Enum.map(subscriptions, &subscription_data/1),
      meta: %{count: length(subscriptions), page: page}
    }
  end

  defp subscription_data(subscription) do
    %{
      id: subscription.id,
      status: subscription.status,
      purchaser_user_id: subscription.purchaser_user_id,
      starts_at: datetime_to_string(subscription.starts_at),
      activated_at: datetime_to_string(subscription.activated_at),
      ends_at: datetime_to_string(subscription.ends_at),
      cancelled_at: datetime_to_string(subscription.cancelled_at),
      recorded_at: datetime_to_string(subscription.recorded_at),
      order: order_data(subscription.order),
      offering: offering_data(subscription.offering),
      current_cycle: cycle_data(subscription.current_cycle),
      balance: subscription.balance
    }
  end

  defp order_data(order) do
    %{
      id: order.id,
      order_number: order.order_number,
      status: order.status,
      placed_at: datetime_to_string(order.placed_at)
    }
  end

  defp offering_data(offering) do
    %{
      version_id: offering.version_id,
      version: offering.version,
      name: offering.name,
      renewal_policy: offering.renewal_policy,
      cycle: offering.cycle
    }
  end

  defp cycle_data(nil), do: nil

  defp cycle_data(cycle) do
    %{
      id: cycle.id,
      sequence: cycle.sequence,
      status: cycle.status,
      starts_at: datetime_to_string(cycle.starts_at),
      ends_at: datetime_to_string(cycle.ends_at)
    }
  end

  defp datetime_to_string(nil), do: nil
  defp datetime_to_string(value), do: DateTime.to_iso8601(value)
end
