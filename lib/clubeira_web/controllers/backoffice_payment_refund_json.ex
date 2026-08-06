defmodule ClubeiraWeb.BackofficePaymentRefundJSON do
  @moduledoc false

  def create(%{refund: refund}) do
    %{
      data: %{
        id: refund.id,
        payment_id: refund.payment_id,
        provider_reference: refund.provider_reference,
        amount: Decimal.to_string(refund.amount, :normal),
        status: refund.status,
        requested_at: DateTime.to_iso8601(refund.requested_at),
        completed_at: DateTime.to_iso8601(refund.completed_at)
      }
    }
  end
end
