defmodule ClubeiraWeb.Member.BillingAgreementJSON do
  @moduledoc false

  def create(%{result: result}) do
    agreement = result.billing_agreement

    %{
      data: %{
        id: agreement.id,
        order_id: result.order_id,
        product_offering_version_id: agreement.product_offering_version_id,
        provider: result.provider,
        status: agreement.status,
        current_period: range(agreement.current_period),
        next_charge_at: datetime(agreement.next_charge_at),
        next_action: agreement.next_action
      }
    }
  end

  def index(%{billing: billing}) do
    %{data: %{agreements: Enum.map(billing.agreements, &agreement_data/1)}}
  end

  defp agreement_data(agreement) do
    %{
      id: agreement.id,
      status: agreement.status,
      current_period: range(agreement.current_period),
      next_charge_at: datetime(agreement.next_charge_at),
      cancelled_at: datetime(agreement.cancelled_at),
      inserted_at: datetime(agreement.inserted_at),
      updated_at: datetime(agreement.updated_at),
      order: nullable_order(agreement.order),
      product_offering_version: agreement.product_offering_version,
      invoices: Enum.map(agreement.invoices, &invoice_data/1)
    }
  end

  defp nullable_order(%{id: nil}), do: nil
  defp nullable_order(order), do: order

  defp invoice_data(invoice) do
    %{
      id: invoice.id,
      order_id: invoice.order_id,
      invoice_number: invoice.invoice_number,
      billing_period: range(invoice.billing_period),
      currency: invoice.currency,
      subtotal_amount: decimal(invoice.subtotal_amount),
      discount_amount: decimal(invoice.discount_amount),
      total_amount: decimal(invoice.total_amount),
      status: invoice.status,
      issued_at: datetime(invoice.issued_at),
      due_at: datetime(invoice.due_at),
      paid_at: datetime(invoice.paid_at),
      inserted_at: datetime(invoice.inserted_at)
    }
  end

  defp range(nil), do: nil

  defp range(%Postgrex.Range{lower: lower, upper: upper}) do
    %{starts_at: datetime(lower), ends_at: range_bound(upper)}
  end

  defp range_bound(:unbound), do: nil
  defp range_bound(value), do: datetime(value)
  defp decimal(value), do: Decimal.to_string(value, :normal)
  defp datetime(nil), do: nil
  defp datetime(value), do: DateTime.to_iso8601(value)
end
