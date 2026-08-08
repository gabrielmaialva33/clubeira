defmodule Clubeira.Security.RedactedInspectTest do
  use ExUnit.Case, async: true

  alias Clubeira.Accounts.EmailVerificationToken
  alias Clubeira.Accounts.PasswordCredential
  alias Clubeira.Accounts.PasswordResetToken
  alias Clubeira.Accounts.Registration
  alias Clubeira.Accounts.UserSession
  alias Clubeira.Devices.DeviceInstallation
  alias Clubeira.Devices.RedemptionEnrollmentRequest
  alias Clubeira.Redemptions.AuthenticatedConfirmationRequest
  alias Clubeira.Redemptions.GrantRequest
  alias Clubeira.Redemptions.ValidationCredential
  alias Clubeira.Redemptions.ValidationCredentialRotationRequest
  alias Clubeira.Redemptions.ValidationPointProvisionRequest

  test "authentication material is redacted by every public struct inspection" do
    secret = "material-que-nunca-pode-aparecer-em-log"

    redacted_fields = [
      {EmailVerificationToken, :token_hash},
      {PasswordCredential, :password_hash},
      {PasswordResetToken, :token_hash},
      {Registration, :password},
      {UserSession, :token_hash},
      {DeviceInstallation, :installation_token_hash},
      {RedemptionEnrollmentRequest, :installation_token},
      {AuthenticatedConfirmationRequest, :validation_credential},
      {GrantRequest, :installation_token},
      {ValidationCredential, :secret_hash},
      {ValidationCredentialRotationRequest, :secret_sha256},
      {ValidationPointProvisionRequest, :secret_sha256}
    ]

    for {module, field} <- redacted_fields do
      inspected = module |> struct(%{field => secret}) |> inspect()

      refute inspected =~ secret
      assert inspected =~ inspect(module)
    end
  end
end
