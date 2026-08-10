defmodule ClubeiraWeb.Member.CheckoutJSON do
  @moduledoc false

  def create(%{order: order}) do
    %{
      data: %{
        id: order.id,
        order_number: order.order_number,
        status: order.status,
        currency: order.currency,
        subtotal_amount: decimal_to_string(order.subtotal_amount),
        discount_amount: decimal_to_string(order.discount_amount),
        total_amount: decimal_to_string(order.total_amount),
        placed_at: DateTime.to_iso8601(order.placed_at)
      }
    }
  end

  defp decimal_to_string(value), do: Decimal.to_string(value, :normal)
end
