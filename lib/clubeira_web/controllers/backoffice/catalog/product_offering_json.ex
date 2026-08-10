defmodule ClubeiraWeb.Backoffice.ProductOfferingJSON do
  @moduledoc false

  def create(%{result: result}), do: %{data: result}

  def index(%{product_offerings: product_offerings, page: page}) do
    %{
      data: Enum.map(product_offerings, &product_offering_data/1),
      meta: %{count: length(product_offerings), page: page}
    }
  end

  defp product_offering_data(offering) do
    %{
      id: offering.id,
      code: offering.code,
      scope_kind: offering.scope_kind,
      sales_channel: offering.sales_channel,
      status: offering.status,
      revision: offering.revision,
      recorded_at: datetime_to_string(offering.recorded_at),
      latest_version: version_data(offering.latest_version)
    }
  end

  defp version_data(nil), do: nil

  defp version_data(version) do
    %Postgrex.Range{lower: effective_from, upper: effective_until} = version.effective_during

    %{
      id: version.id,
      version: version.version,
      name: version.name,
      description: version.description,
      status: version.status,
      activation_policy: version.activation_policy,
      renewal_policy: version.renewal_policy,
      effective_from: datetime_to_string(effective_from),
      effective_until: range_bound_to_string(effective_until),
      cycle: %{
        policy: version.cycle_policy,
        interval_unit: version.cycle_interval_unit,
        interval_count: version.cycle_interval_count
      },
      prices: Enum.map(version.prices, &price_data/1)
    }
  end

  defp price_data(price) do
    %Postgrex.Range{lower: valid_from, upper: valid_until} = price.valid_during

    %{
      id: price.id,
      key: price.key,
      currency: price.currency,
      amount: Decimal.to_string(price.amount, :normal),
      billing_model: price.billing_model,
      interval_unit: price.interval_unit,
      interval_count: price.interval_count,
      installments: price.installments,
      valid_from: datetime_to_string(valid_from),
      valid_until: range_bound_to_string(valid_until)
    }
  end

  defp datetime_to_string(value), do: DateTime.to_iso8601(value)
  defp range_bound_to_string(:unbound), do: nil
  defp range_bound_to_string(value), do: datetime_to_string(value)
end
