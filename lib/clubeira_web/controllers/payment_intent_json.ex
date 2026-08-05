defmodule ClubeiraWeb.PaymentIntentJSON do
  @moduledoc false

  def create(%{payment: %{payment_intent: intent, provider: provider}}) do
    %{
      data: %{
        id: intent.id,
        order_id: intent.order_id,
        provider: provider,
        provider_reference: intent.provider_reference,
        payment_method: intent.payment_method,
        status: intent.status,
        amount: Decimal.to_string(intent.amount, :normal),
        currency: intent.currency,
        expires_at: DateTime.to_iso8601(intent.expires_at),
        next_action: intent.next_action
      }
    }
  end
end
