defmodule Clubeira.Partnerships.RequestBoundaryTest do
  use ExUnit.Case, async: true

  alias Clubeira.Partnerships
  alias Clubeira.Partnerships.AgreementPublishRequest
  alias Clubeira.Tenancy.Scope

  test "builds the agreement publication form through the public context" do
    assert %Ecto.Changeset{valid?: true, changes: %{}} =
             Partnerships.change_agreement_publish_request()

    organization_id = Ecto.UUID.generate(version: 7)
    polo_place_id = Ecto.UUID.generate(version: 7)
    offer_version_id = Ecto.UUID.generate(version: 7)

    changeset =
      Partnerships.change_agreement_publish_request(%{
        "agreement_number" => "AGR-2026-001",
        "name" => "Acordo comercial",
        "valid_from" => "2026-08-12T12:00:00Z",
        "valid_until" => "2027-08-12T12:00:00Z",
        "signed_at" => "2026-08-11T12:00:00Z",
        "settlement_model" => "none",
        "redemption_sla_seconds" => "30",
        "organization_ids" => [organization_id],
        "polo_place_ids" => [polo_place_id],
        "benefit_offer_version_ids" => [offer_version_id],
        "idempotency_key" => "agreement-publish-form"
      })

    assert changeset.valid?
    assert %AgreementPublishRequest{} = changeset.data
    assert Ecto.Changeset.get_field(changeset, :redemption_sla_seconds) == 30

    assert DateTime.compare(
             Ecto.Changeset.get_field(changeset, :valid_from),
             ~U[2026-08-12 12:00:00Z]
           ) == :eq

    assert Ecto.Changeset.get_field(changeset, :organization_ids) == [organization_id]
  end

  test "form and command boundaries reject structured payloads without raising" do
    Enum.each([:invalid, %URI{}], fn attributes ->
      changeset = Partnerships.change_agreement_publish_request(attributes)

      refute changeset.valid?
      assert {:base, {"must be a map", []}} in changeset.errors
    end)

    scope =
      Scope.new!(Ecto.UUID.generate(version: 7),
        actor_user_id: Ecto.UUID.generate(version: 7)
      )

    assert {:error, %Ecto.Changeset{} = command_error} =
             Partnerships.publish_agreement(scope, %URI{})

    assert {:base, {"must be a map", []}} in command_error.errors
  end
end
