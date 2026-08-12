defmodule Clubeira.Subscriptions.ProductOfferingRequestTest do
  use ExUnit.Case, async: true

  alias Clubeira.Subscriptions
  alias Clubeira.Subscriptions.ProductOfferingLifecycleRequest
  alias Clubeira.Subscriptions.ProductOfferingPublishRequest

  test "the publication form boundary exposes nested benefit changesets" do
    changeset =
      Subscriptions.change_product_offering_publish_request(%{
        "code" => "clube-anual",
        "benefits" => [
          %{
            "benefit_offer_version_id" => Ecto.UUID.generate(),
            "allowance_per_cycle" => "2",
            "consumption_unit" => "shared_scope"
          }
        ]
      })

    assert Ecto.Changeset.get_field(changeset, :code) == "clube-anual"
    assert [%Ecto.Changeset{}] = Ecto.Changeset.get_change(changeset, :benefits)

    Enum.each([:invalid, %ProductOfferingPublishRequest{}], fn attributes ->
      invalid = Subscriptions.change_product_offering_publish_request(attributes)

      refute invalid.valid?
      assert {:base, {"must be a map", []}} in invalid.errors
    end)
  end

  test "the lifecycle form boundary rejects non-map payloads without raising" do
    changeset =
      Subscriptions.change_product_offering_lifecycle_request(%{
        "action" => "pause",
        "reason" => "Pausa comercial planejada."
      })

    assert Ecto.Changeset.get_field(changeset, :action) == "pause"

    Enum.each([:invalid, %ProductOfferingLifecycleRequest{}], fn attributes ->
      invalid = Subscriptions.change_product_offering_lifecycle_request(attributes)

      refute invalid.valid?
      assert {:base, {"must be a map", []}} in invalid.errors
    end)
  end

  test "the lifecycle command normalizes actions and returns validation changesets" do
    assert {:ok, request} =
             ProductOfferingLifecycleRequest.new(%{
               action: " PAUSE ",
               reason: "  Pausa comercial planejada.  ",
               idempotency_key: "offering-lifecycle-001"
             })

    assert request.action == "pause"
    assert request.reason == "Pausa comercial planejada."

    for attributes <- [
          :invalid,
          %ProductOfferingLifecycleRequest{},
          %{action: 1, reason: 2, idempotency_key: "invalid key"}
        ] do
      assert {:error, changeset} = ProductOfferingLifecycleRequest.new(attributes)
      refute changeset.valid?
    end
  end
end
