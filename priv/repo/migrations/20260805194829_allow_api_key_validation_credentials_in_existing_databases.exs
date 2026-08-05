defmodule Clubeira.Repo.Migrations.AllowApiKeyValidationCredentialsInExistingDatabases do
  use Ecto.Migration

  @legacy_kinds "kind IN ('static_qr', 'rotating_qr', 'nfc', 'manual_code', 'public_key')"

  @current_kinds "kind IN ('static_qr', 'rotating_qr', 'nfc', 'manual_code', 'public_key', 'api_key')"

  def up do
    create_if_not_exists unique_index(:validation_credentials, [:secret_hash],
                           name: :validation_credentials_secret_hash_uidx,
                           where: "secret_hash IS NOT NULL"
                         )

    drop constraint(:validation_credentials, :validation_credentials_kind_check,
           check: @legacy_kinds
         )

    create constraint(:validation_credentials, :validation_credentials_kind_check,
             check: @current_kinds
           )

    execute("""
    UPDATE validation_credentials AS credential
    SET kind = 'api_key'
    FROM validation_points AS point
    WHERE point.id = credential.validation_point_id
      AND point.polo_id = credential.polo_id
      AND point.kind = 'api'
      AND credential.kind = 'manual_code'
    """)
  end

  def down do
    execute("""
    UPDATE validation_credentials AS credential
    SET kind = 'manual_code'
    FROM validation_points AS point
    WHERE point.id = credential.validation_point_id
      AND point.polo_id = credential.polo_id
      AND point.kind = 'api'
      AND credential.kind = 'api_key'
    """)

    drop constraint(:validation_credentials, :validation_credentials_kind_check,
           check: @current_kinds
         )

    create constraint(:validation_credentials, :validation_credentials_kind_check,
             check: @legacy_kinds
           )

    drop_if_exists index(:validation_credentials, [:secret_hash],
                     name: :validation_credentials_secret_hash_uidx,
                     where: "secret_hash IS NOT NULL"
                   )
  end
end
