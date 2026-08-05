defmodule ClubeiraWeb.OrderJSON do
  @moduledoc false

  def index(%{orders: orders, page: page}) do
    %{
      data: Enum.map(orders, &order_data/1),
      meta: %{count: length(orders), page: page}
    }
  end

  defp order_data(order) do
    %{
      id: order.id,
      order_number: order.order_number,
      status: order.status,
      currency: order.currency,
      subtotal_amount: decimal_to_string(order.subtotal_amount),
      discount_amount: decimal_to_string(order.discount_amount),
      total_amount: decimal_to_string(order.total_amount),
      placed_at: datetime_to_string(order.placed_at),
      cancelled_at: datetime_to_string(order.cancelled_at),
      items: Enum.map(order.items, &item_data/1)
    }
  end

  defp item_data(item) do
    %{
      id: item.id,
      product_offering_version_id: item.product_offering_version_id,
      offering_price_id: item.offering_price_id,
      name: item.name,
      description: item.description,
      quantity: item.quantity,
      unit_amount: decimal_to_string(item.unit_amount),
      total_amount: decimal_to_string(item.total_amount)
    }
  end

  defp decimal_to_string(value), do: Decimal.to_string(value, :normal)

  defp datetime_to_string(nil), do: nil
  defp datetime_to_string(value), do: DateTime.to_iso8601(value)
end
