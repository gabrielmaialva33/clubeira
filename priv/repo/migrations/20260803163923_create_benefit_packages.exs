defmodule Clubeira.Repo.Migrations.CreateBenefitPackages do
  use Ecto.Migration

  @timestamps_opts [type: :timestamptz, null: false, default: fragment("now()")]

  def change do
    create table(:benefit_packages, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      add :polo_id, references(:polos, type: :uuid, on_delete: :restrict), null: false
      add :code, :citext, null: false
      add :name, :text, null: false
      add :status, :text, null: false, default: "draft"

      timestamps(@timestamps_opts)
    end

    create unique_index(:benefit_packages, [:polo_id, :code])

    create unique_index(:benefit_packages, [:id, :polo_id], name: :benefit_packages_id_polo_uidx)

    create constraint(:benefit_packages, :benefit_packages_status_check,
             check: "status IN ('draft', 'active', 'retired')"
           )
  end
end
