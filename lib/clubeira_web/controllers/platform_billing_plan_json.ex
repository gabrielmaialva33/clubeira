defmodule ClubeiraWeb.PlatformBillingPlanJSON do
  @moduledoc false

  def index(%{plans: plans}), do: %{data: Enum.map(plans, &plan_data/1)}
  def show(%{plan: plan}), do: %{data: plan_data(plan)}

  defp plan_data(plan) do
    %{
      id: plan.id,
      code: plan.code,
      name: plan.name,
      status: plan.status,
      version: version_data(plan.version)
    }
  end

  defp version_data(version) do
    %{
      id: version.id,
      version: version.version,
      name: version.name,
      description: version.description,
      status: version.status,
      published_at: datetime(version.published_at),
      features: Enum.map(version.features, &feature_data/1),
      price: price_data(version.price)
    }
  end

  defp feature_data(feature) do
    %{
      key: feature.key,
      name: feature.name,
      value_kind: feature.value_kind,
      boolean_value: feature.boolean_value,
      integer_value: feature.integer_value
    }
  end

  defp price_data(price) do
    %{
      id: price.id,
      currency: price.currency,
      amount: Decimal.to_string(price.amount),
      billing_interval_unit: price.billing_interval_unit,
      billing_interval_count: price.billing_interval_count,
      valid_from: range_bound(price.valid_during.lower),
      valid_until: range_bound(price.valid_during.upper)
    }
  end

  defp datetime(nil), do: nil
  defp datetime(value), do: DateTime.to_iso8601(value)
  defp range_bound(:unbound), do: nil
  defp range_bound(value), do: DateTime.to_iso8601(value)
end
