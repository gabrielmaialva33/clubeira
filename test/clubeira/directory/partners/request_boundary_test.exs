defmodule Clubeira.Directory.PartnerRequestBoundaryTest do
  use ExUnit.Case, async: true

  alias Clubeira.Directory
  alias Clubeira.Directory.PartnerAccessGrantRequest
  alias Clubeira.Directory.PartnerAccessRevocationRequest
  alias Clubeira.Directory.PartnerOnboardingRequest
  alias Clubeira.Tenancy.Scope

  test "builds partner access forms through the public context" do
    assert %Ecto.Changeset{valid?: true, changes: %{}} =
             Directory.change_partner_access_grant_request()

    assert %Ecto.Changeset{valid?: true, changes: %{}} =
             Directory.change_partner_access_revocation_request()

    grant =
      Directory.change_partner_access_grant_request(%{
        "email" => "partner@example.com",
        "idempotency_key" => "partner-access-grant-form"
      })

    assert %PartnerAccessGrantRequest{} = grant.data
    assert Ecto.Changeset.get_field(grant, :email) == "partner@example.com"
    assert Ecto.Changeset.get_field(grant, :idempotency_key) == "partner-access-grant-form"

    revocation =
      Directory.change_partner_access_revocation_request(%{
        "reason" => "Responsável desligado",
        "idempotency_key" => "partner-access-revoke-form"
      })

    assert %PartnerAccessRevocationRequest{} = revocation.data
    assert Ecto.Changeset.get_field(revocation, :reason) == "Responsável desligado"

    assert Ecto.Changeset.get_field(revocation, :idempotency_key) ==
             "partner-access-revoke-form"
  end

  test "builds the partner onboarding form and rejects structured payloads" do
    changeset =
      Directory.change_partner_onboarding_request(%{
        "legal_name" => "Sabores da Serra Alimentos Ltda.",
        "trade_name" => "Sabores da Serra",
        "place_name" => "Sabores da Serra Centro"
      })

    assert %PartnerOnboardingRequest{} = changeset.data

    assert Ecto.Changeset.get_field(changeset, :legal_name) ==
             "Sabores da Serra Alimentos Ltda."

    Enum.each([:invalid, %PartnerOnboardingRequest{}], fn attributes ->
      invalid = Directory.change_partner_onboarding_request(attributes)

      refute invalid.valid?
      assert {:base, {"must be a map", []}} in invalid.errors
    end)
  end

  test "form and command boundaries reject structured payloads without raising" do
    Enum.each([:invalid, %URI{}], fn attributes ->
      Enum.each(
        [
          Directory.change_partner_access_grant_request(attributes),
          Directory.change_partner_access_revocation_request(attributes)
        ],
        fn changeset ->
          refute changeset.valid?
          assert {:base, {"must be a map", []}} in changeset.errors
        end
      )
    end)

    polo_id = Ecto.UUID.generate(version: 7)
    actor_id = Ecto.UUID.generate(version: 7)
    resource_id = Ecto.UUID.generate(version: 7)
    scope = Scope.new!(polo_id, actor_user_id: actor_id)

    assert {:error, %Ecto.Changeset{} = grant_error} =
             Directory.grant_partner_access(scope, resource_id, %URI{})

    assert {:base, {"must be a map", []}} in grant_error.errors

    assert {:error, %Ecto.Changeset{} = revocation_error} =
             Directory.revoke_partner_access(scope, resource_id, %URI{})

    assert {:base, {"must be a map", []}} in revocation_error.errors
  end
end
