defmodule Clubeira.Security.RedactedInspectTest do
  use ExUnit.Case, async: true

  @secret "clubeira-secret-that-must-never-be-logged"

  test "every credential-bearing schema redacts its sensitive fields from Inspect" do
    schemas = [
      {Clubeira.Accounts.EmailVerificationSubmission, token: @secret},
      {Clubeira.Accounts.EmailVerificationToken, token_hash: @secret},
      {Clubeira.Accounts.PasswordCredential, password_hash: @secret, password: @secret},
      {Clubeira.Accounts.PasswordResetCompletion, token: @secret, password: @secret},
      {Clubeira.Accounts.PasswordResetToken, token_hash: @secret},
      {Clubeira.Accounts.Registration, password: @secret},
      {Clubeira.Accounts.UserSession, token_hash: @secret},
      {Clubeira.Devices.DeviceInstallation, installation_token_hash: @secret},
      {Clubeira.Devices.DeviceKey, public_key: @secret},
      {Clubeira.Devices.DeviceKeyRegistrationRequest,
       installation_token: @secret, public_key: @secret, proof: @secret},
      {Clubeira.Devices.RedemptionEnrollmentRequest, installation_token: @secret},
      {Clubeira.People.PersonContactPoint, ciphertext: @secret, lookup_token: @secret},
      {Clubeira.People.PersonIdentifier, ciphertext: @secret, lookup_token: @secret},
      {Clubeira.People.SelfProfileRequest, cpf: @secret, phone: @secret},
      {Clubeira.Privacy.Request, request_sha256: @secret},
      {Clubeira.Redemptions.AuthenticatedConfirmationRequest,
       grant: @secret, validation_credential: @secret},
      {Clubeira.Redemptions.GrantRequest, installation_token: @secret},
      {Clubeira.Redemptions.ValidationCredential, secret_hash: @secret},
      {Clubeira.Redemptions.ValidationCredentialRotationRequest, secret_sha256: @secret},
      {Clubeira.Redemptions.ValidationPointProvisionRequest, secret_sha256: @secret},
      {Clubeira.Reviews.ReviewMedia, storage_key: @secret, content_sha256: @secret},
      {Clubeira.Reviews.ReviewMediaRequest, storage_key: @secret}
    ]

    for {schema, attributes} <- schemas do
      rendered = schema |> struct(attributes) |> inspect()

      refute rendered =~ @secret, "#{inspect(schema)} leaked a redacted field"
      assert String.ends_with?(rendered, "...>")
    end
  end
end
