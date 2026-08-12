defmodule Clubeira.Platform.RequestBoundaryTest do
  use ExUnit.Case, async: true

  alias Clubeira.Platform.PlanPublishRequest
  alias Clubeira.Platform.SubscriptionStartRequest
  alias Clubeira.PlatformBilling

  test "the plan publication form boundary exposes nested features and rejects invalid payload shapes" do
    now = DateTime.utc_now(:microsecond)

    changeset =
      PlatformBilling.change_plan_publish_request(%{
        "name" => "Operação",
        "version_name" => "Operação 2026",
        "description" => "Plano operacional para polos em crescimento.",
        "currency" => "brl",
        "amount" => "399.90",
        "billing_interval_unit" => "month",
        "billing_interval_count" => "1",
        "valid_from" => DateTime.add(now, -60),
        "valid_until" => DateTime.add(now, 31_536_000),
        "features" => [
          %{
            "key" => "partner_limit",
            "name" => "Limite de parceiros",
            "value_kind" => "integer",
            "integer_value" => "250"
          }
        ]
      })

    assert changeset.valid?
    assert changeset.action == nil
    assert Ecto.Changeset.get_field(changeset, :currency) == "BRL"
    assert [%Ecto.Changeset{}] = Ecto.Changeset.get_change(changeset, :features)

    Enum.each([:invalid, %PlanPublishRequest{}], fn attributes ->
      invalid = PlatformBilling.change_plan_publish_request(attributes)

      refute invalid.valid?
      assert {:base, {"must be a map", []}} in invalid.errors
    end)
  end

  test "the subscription start form boundary casts values and rejects invalid payload shapes" do
    price_id = Ecto.UUID.generate()

    changeset =
      PlatformBilling.change_subscription_start_request(%{
        "platform_price_id" => price_id,
        "idempotency_key" => "platform-subscription-form-001"
      })

    assert changeset.valid?
    assert changeset.action == nil
    assert Ecto.Changeset.get_field(changeset, :platform_price_id) == price_id

    assert Ecto.Changeset.get_field(changeset, :idempotency_key) ==
             "platform-subscription-form-001"

    Enum.each([:invalid, %SubscriptionStartRequest{}], fn attributes ->
      invalid = PlatformBilling.change_subscription_start_request(attributes)

      refute invalid.valid?
      assert {:base, {"must be a map", []}} in invalid.errors
    end)
  end
end
