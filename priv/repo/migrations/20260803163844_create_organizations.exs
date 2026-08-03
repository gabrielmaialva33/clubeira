defmodule Clubeira.Repo.Migrations.CreateOrganizations do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:organizations, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :kind, :text, null: false
      add :legal_name, :text, null: false
      add :trade_name, :text
      add :country_code, :string, size: 2, null: false, default: "BR"
      add :status, :text, null: false, default: "active"

      timestamps(@timestamps_opts)
    end

    create index(:organizations, [:trade_name])

    create constraint(:organizations, :organizations_kind_check,
             check: "kind IN ('legal_entity', 'individual_business', 'platform')"
           )

    create constraint(:organizations, :organizations_status_check,
             check: "status IN ('prospect', 'active', 'suspended', 'closed')"
           )

    create constraint(:organizations, :organizations_country_code_check,
             check: "country_code = upper(country_code) AND char_length(country_code) = 2"
           )
  end
end
