defmodule Clubeira.Redemptions.ValidationRequestBoundaryTest do
  use ExUnit.Case, async: true

  alias Clubeira.Redemptions
  alias Clubeira.Redemptions.ValidationCredentialRevocationRequest
  alias Clubeira.Redemptions.ValidationCredentialRotationRequest
  alias Clubeira.Redemptions.ValidationPointLifecycleRequest
  alias Clubeira.Redemptions.ValidationPointProvisionRequest

  test "builds the validation-point provisioning form through the public context" do
    expires_at = ~U[2030-01-01 12:00:00.000000Z]

    changeset =
      Redemptions.change_validation_point_provision_request(%{
        name: "Caixa principal",
        secret_sha256: "digest-for-the-form",
        expires_at: expires_at,
        idempotency_key: "validation-point-form-001"
      })

    assert changeset.action == nil
    assert Ecto.Changeset.get_change(changeset, :name) == "Caixa principal"
    assert Ecto.Changeset.get_change(changeset, :secret_sha256) == "digest-for-the-form"
    assert Ecto.Changeset.get_change(changeset, :expires_at) == expires_at

    assert Ecto.Changeset.get_change(changeset, :idempotency_key) ==
             "validation-point-form-001"
  end

  test "builds the validation-point lifecycle form through the public context" do
    changeset =
      Redemptions.change_validation_point_lifecycle_request(%{
        action: "retire",
        reason: "Ponto removido da operação",
        idempotency_key: "validation-point-lifecycle-form-001"
      })

    assert changeset.action == nil
    assert Ecto.Changeset.get_change(changeset, :action) == "retire"
    assert Ecto.Changeset.get_change(changeset, :reason) == "Ponto removido da operação"

    assert Ecto.Changeset.get_change(changeset, :idempotency_key) ==
             "validation-point-lifecycle-form-001"
  end

  test "builds the validation-credential rotation form through the public context" do
    expires_at = ~U[2031-02-03 14:30:00.000000Z]

    changeset =
      Redemptions.change_validation_credential_rotation_request(%{
        secret_sha256: "replacement-digest-for-the-form",
        expires_at: expires_at,
        idempotency_key: "validation-credential-rotation-form-001"
      })

    assert changeset.action == nil

    assert Ecto.Changeset.get_change(changeset, :secret_sha256) ==
             "replacement-digest-for-the-form"

    assert Ecto.Changeset.get_change(changeset, :expires_at) == expires_at

    assert Ecto.Changeset.get_change(changeset, :idempotency_key) ==
             "validation-credential-rotation-form-001"
  end

  test "builds the validation-credential revocation form through the public context" do
    changeset =
      Redemptions.change_validation_credential_revocation_request(%{
        idempotency_key: "validation-credential-revocation-form-001"
      })

    assert changeset.action == nil

    assert Ecto.Changeset.get_change(changeset, :idempotency_key) ==
             "validation-credential-revocation-form-001"
  end

  test "public validation form boundaries reject non-map and struct payloads without raising" do
    boundaries = [
      {&Redemptions.change_validation_point_provision_request/1,
       %ValidationPointProvisionRequest{}},
      {&Redemptions.change_validation_point_lifecycle_request/1,
       %ValidationPointLifecycleRequest{}},
      {&Redemptions.change_validation_credential_rotation_request/1,
       %ValidationCredentialRotationRequest{}},
      {&Redemptions.change_validation_credential_revocation_request/1,
       %ValidationCredentialRevocationRequest{}}
    ]

    Enum.each(boundaries, fn {change_request, request_struct} ->
      Enum.each([:invalid, request_struct], fn attributes ->
        changeset = change_request.(attributes)

        refute changeset.valid?
        assert {:base, {"must be a map", []}} in changeset.errors
      end)
    end)
  end

  test "validation request constructors reject non-map and struct payloads without raising" do
    requests = [
      {&ValidationPointProvisionRequest.new/1, %ValidationPointProvisionRequest{}},
      {&ValidationPointLifecycleRequest.new/1, %ValidationPointLifecycleRequest{}},
      {&ValidationCredentialRotationRequest.new/1, %ValidationCredentialRotationRequest{}},
      {&ValidationCredentialRevocationRequest.new/1, %ValidationCredentialRevocationRequest{}}
    ]

    Enum.each(requests, fn {new_request, request_struct} ->
      Enum.each([:invalid, request_struct], fn attributes ->
        assert {:error, changeset} = new_request.(attributes)
        assert {:base, {"must be a map", []}} in changeset.errors
      end)
    end)
  end

  test "validation-point lifecycle constructor normalizes strings and rejects typed garbage" do
    assert {:ok, request} =
             ValidationPointLifecycleRequest.new(%{
               action: " SUSPEND ",
               reason: "  Manutenção preventiva.  ",
               idempotency_key: "validation-lifecycle-001"
             })

    assert request.action == "suspend"
    assert request.reason == "Manutenção preventiva."

    assert {:error, changeset} =
             ValidationPointLifecycleRequest.new(%{
               action: 1,
               reason: 2,
               idempotency_key: "invalid key"
             })

    refute changeset.valid?
  end
end
