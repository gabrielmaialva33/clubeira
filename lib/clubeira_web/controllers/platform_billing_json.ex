defmodule ClubeiraWeb.PlatformBillingJSON do
  @moduledoc false

  def show(%{billing: billing}) do
    %{
      data: %{
        subscription: subscription_data(billing.subscription),
        invoices: Enum.map(billing.invoices, &invoice_data/1)
      }
    }
  end

  defp subscription_data(nil), do: nil

  defp subscription_data(subscription) do
    %{
      id: subscription.id,
      status: subscription.status,
      current_period: period(subscription.current_period),
      next_charge_at: datetime(subscription.next_charge_at),
      cancelled_at: datetime(subscription.cancelled_at),
      inserted_at: datetime(subscription.inserted_at),
      updated_at: datetime(subscription.updated_at),
      plan: %{
        code: subscription.plan.code,
        name: subscription.plan.name,
        version: subscription.plan.version,
        version_name: subscription.plan.version_name,
        features: subscription.plan.features,
        price: %{
          currency: subscription.plan.price.currency,
          amount: decimal(subscription.plan.price.amount),
          billing_interval_unit: subscription.plan.price.billing_interval_unit,
          billing_interval_count: subscription.plan.price.billing_interval_count
        }
      }
    }
  end

  defp invoice_data(invoice) do
    %{
      id: invoice.id,
      invoice_number: invoice.invoice_number,
      billing_period: period(invoice.billing_period),
      currency: invoice.currency,
      subtotal_amount: decimal(invoice.subtotal_amount),
      discount_amount: decimal(invoice.discount_amount),
      total_amount: decimal(invoice.total_amount),
      status: invoice.status,
      issued_at: datetime(invoice.issued_at),
      due_at: datetime(invoice.due_at),
      paid_at: datetime(invoice.paid_at),
      inserted_at: datetime(invoice.inserted_at),
      items: Enum.map(invoice.items, &invoice_item_data/1),
      payment: payment_data(invoice.payment)
    }
  end

  defp invoice_item_data(item) do
    %{
      id: item.id,
      item_kind: item.item_kind,
      description: item.description,
      quantity: item.quantity,
      unit_amount: decimal(item.unit_amount),
      total_amount: decimal(item.total_amount)
    }
  end

  defp payment_data(nil), do: nil

  defp payment_data(payment) do
    %{
      id: payment.id,
      currency: payment.currency,
      amount: decimal(payment.amount),
      status: payment.status,
      paid_at: datetime(payment.paid_at),
      inserted_at: datetime(payment.inserted_at)
    }
  end

  defp period(nil), do: nil

  defp period(value) do
    %{starts_at: datetime(value.starts_at), ends_at: datetime(value.ends_at)}
  end

  defp datetime(nil), do: nil
  defp datetime(value), do: DateTime.to_iso8601(value)
  defp decimal(value), do: Decimal.to_string(value)
end
