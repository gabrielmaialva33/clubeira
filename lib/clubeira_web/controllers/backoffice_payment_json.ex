defmodule ClubeiraWeb.BackofficePaymentJSON do
  @moduledoc false

  def index(%{payments: payments, page: page}) do
    %{
      data: Enum.map(payments, &payment_data/1),
      meta: %{count: length(payments), page: page}
    }
  end

  defp payment_data(payment) do
    %{
      id: payment.id,
      status: payment.status,
      amount: decimal_to_string(payment.amount),
      currency: payment.currency,
      payment_method: payment.payment_method,
      provider_code: payment.provider_code,
      captured_at: datetime_to_string(payment.captured_at),
      refunded_at: datetime_to_string(payment.refunded_at),
      recorded_at: datetime_to_string(payment.recorded_at),
      order: order_data(payment.order),
      refund: refund_data(payment.refund)
    }
  end

  defp order_data(order) do
    %{
      id: order.id,
      order_number: order.order_number,
      status: order.status,
      purchaser_user_id: order.purchaser_user_id,
      placed_at: datetime_to_string(order.placed_at)
    }
  end

  defp refund_data(nil), do: nil

  defp refund_data(refund) do
    %{
      id: refund.id,
      status: refund.status,
      amount: decimal_to_string(refund.amount),
      requested_at: datetime_to_string(refund.requested_at),
      completed_at: datetime_to_string(refund.completed_at)
    }
  end

  defp decimal_to_string(value), do: Decimal.to_string(value, :normal)

  defp datetime_to_string(nil), do: nil
  defp datetime_to_string(value), do: DateTime.to_iso8601(value)
end
